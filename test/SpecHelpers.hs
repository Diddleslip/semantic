module SpecHelpers
( module X
, diffFilePaths
, parseFilePath
, readFilePair
, testEvaluating
, ns
, addr
, verbatim
, Verbatim(..)
) where

import Analysis.Abstract.Evaluating
import Analysis.Abstract.Evaluating as X (EvaluatingState(..))
import Control.Abstract.Addressable
import Control.Abstract.Value
import Control.Effect as X (runIgnoringTraces)
import Data.Abstract.Address as X
import Data.Abstract.Evaluatable
import Data.Abstract.FreeVariables as X hiding (dropExtension)
import Data.Abstract.Heap as X
import Data.Abstract.ModuleTable as X hiding (lookup)
import Data.Abstract.Value (Namespace(..), Value, ValueError, injValue, runValueError)
import Data.Bifunctor (first)
import Data.Blob as X
import Data.File as X
import Data.Functor.Listable as X
import Data.Language as X
import Data.Output as X
import Data.Range as X
import Data.Record as X
import Data.Source as X
import Data.Span as X
import Data.Term as X
import Parsing.Parser as X
import Rendering.Renderer as X
import Semantic.Diff as X
import Semantic.Parse as X
import Semantic.Task as X hiding (parsePackage)
import Semantic.Util as X
import System.FilePath as X

import Data.ByteString as X (ByteString)
import Data.Functor.Both as X (Both, runBothWith, both)
import Data.Maybe as X
import Data.Monoid as X (Monoid(..), First(..), Last(..))
import Data.Semigroup as X (Semigroup(..))
import Control.Monad as X

import Test.Hspec as X (Spec, SpecWith, context, describe, it, xit, parallel, pendingWith, around, runIO)
import Test.Hspec.Expectations.Pretty as X
import Test.Hspec.LeanCheck as X
import Test.LeanCheck as X

import qualified Data.ByteString as B
import qualified Semantic.IO as IO

-- | Returns an s-expression formatted diff for the specified FilePath pair.
diffFilePaths :: Both FilePath -> IO ByteString
diffFilePaths paths = readFilePair paths >>= runTask . diffBlobPair SExpressionDiffRenderer

-- | Returns an s-expression parse tree for the specified FilePath.
parseFilePath :: FilePath -> IO ByteString
parseFilePath path = (fromJust <$> IO.readFile (file path)) >>= runTask . parseBlob SExpressionTermRenderer

-- | Read two files to a BlobPair.
readFilePair :: Both FilePath -> IO BlobPair
readFilePair paths = let paths' = fmap file paths in
                     runBothWith IO.readFilePair paths'

testEvaluating
  = run
  . fmap (first reassociate)
  . evaluating
  . runIgnoringTraces
  . runLoadError
  . runValueError
  . runUnspecialized
  . runResolutionError
  . runEnvironmentError
  . runEvalError
  . runAddressError
  . constrainedToValuePrecise

ns n = Just . Latest . Just . injValue . Namespace n
addr = Address . Precise

newtype Verbatim = Verbatim ByteString
  deriving (Eq)

instance Show Verbatim where
  show (Verbatim x) = show x

verbatim :: ByteString -> Verbatim
verbatim = Verbatim . stripWhitespace
  where
    stripWhitespace :: ByteString -> ByteString
    stripWhitespace = B.foldl' go B.empty
      where go acc x | x `B.elem` " \t\n" = acc
                     | otherwise = B.snoc acc x
