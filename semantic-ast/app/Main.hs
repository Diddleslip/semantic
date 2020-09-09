{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleInstances #-}

module Main (main) where

import AST.GenerateSyntax
import Data.Maybe
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as T
import GHC.Generics (Generic)
import Language.Haskell.TH
import NeatInterpolation
import qualified Options.Generic as Opt
import System.Directory
import Debug.Trace
import System.IO
import System.Process
import qualified Language.Haskell.TH.PprLib as Doc
import Language.Haskell.TH.PprLib (Doc)
import qualified TreeSitter.JSON as JSON (tree_sitter_json)

data Config = Config
  { language :: Text,
    path :: FilePath
  }
  deriving (Show, Generic)

instance Opt.ParseRecord Config

instance Ppr Doc where ppr = id

header :: Text
header =
  [trimming|
{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE QuantifiedConstraints #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -fno-warn-unused-imports #-}
|]

imports :: Text
imports =
  [trimming|
import qualified AST.Parse
import qualified AST.Token
import qualified AST.Traversable1.Class
import qualified AST.Unmarshal
import qualified Data.Foldable
import qualified Data.List as Data.OldList
import qualified Data.Maybe as GHC.Maybe
import qualified Data.Text.Internal
import qualified Data.Traversable
import qualified GHC.Base
import qualified GHC.Generics
import qualified GHC.Records
import qualified GHC.Show
import qualified Prelude as GHC.Classes
import qualified TreeSitter.Node

debugSymbolNames :: [GHC.Base.String]
debugSymbolNames = debugSymbolNames_0
|]

class Ppr a => Pretty a where
  pretty :: a -> Doc
  pretty = ppr

instance Pretty a => Pretty [a] where
  pretty = Doc.vcat . fmap pretty

instance Pretty Dec where
  pretty x = case x of
    InstanceD ol cxt typ bindings ->
      let adjust = \case
            ValD (VarP lhs) bod decs -> traceShow x (ValD (VarP (mkName . nameBase $ lhs)) bod decs)
            FunD n cs -> FunD (mkName . nameBase $ n) cs
            y -> traceShowId y
          in ppr (InstanceD ol cxt typ (fmap adjust bindings))
    other -> traceShow other (ppr other)

main :: IO ()
main = do
  Config language path <- Opt.getRecord "generate-ast"
  absolute <- makeAbsolute path
  decls <- runQ (astDeclarationsRelative JSON.tree_sitter_json absolute)

  let modheader =
        [trimming| module Language.$language.AST (module Language.$language.AST) where
              -- Language definition for $language, generated by ast-generate. Do not edit!
                      |]

  let programText = T.unlines [header, modheader, imports, T.pack (pprint (pretty decls))]
  hasOrmolu <- findExecutable "ormolu"
  if isNothing hasOrmolu
    then T.putStrLn programText
    else do
      (path, tf) <- openTempFile "/tmp" "generated.hs"
      T.hPutStrLn tf programText
      hClose tf
      callProcess "sed" ["-i", "-e", "s/AST.Traversable1.Class.Traversable1 someConstraint/(AST.Traversable1.Class.Traversable1 someConstraint)/g", path]
      callProcess "ormolu" ["--mode", "inplace", path]
      readFile path >>= putStrLn
