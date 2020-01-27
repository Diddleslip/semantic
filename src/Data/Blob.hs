{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE ExplicitNamespaces #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
module Data.Blob
( File(..)
, fileForPath
, fileForTypedPath
, Blob(..)
, Blobs(..)
, blobLanguage
, NoLanguageForBlob (..)
, blobPath
, makeBlob
, decodeBlobs
, nullBlob
, sourceBlob
, moduleForBlob
, noLanguageForBlob
, BlobPair
, maybeBlobPair
, decodeBlobPairs
, languageForBlobPair
, languageTagForBlobPair
, pathForBlobPair
, pathKeyForBlobPair
) where

import           Control.Effect.Error
import           Control.Exception
import           Data.Aeson
import           Data.Bifunctor
import qualified Data.ByteString.Lazy as BL
import           Data.Edit
import           Data.JSON.Fields
import           Data.Language
import           Data.Maybe
import           Data.Maybe.Exts
import           Data.Module
import           Data.Text (Text)
import           GHC.Generics (Generic)
import           Source.Source (Source)
import qualified Source.Source as Source
import qualified System.FilePath as FP
import qualified System.Path as Path
import qualified System.Path.PartClass as Path.PartClass

-- | A 'FilePath' paired with its corresponding 'Language'.
-- Unpacked to have the same size overhead as (FilePath, Language).
data File = File
  { filePath     :: FilePath
  , fileLanguage :: Language
  } deriving (Show, Eq)

-- | Prefer 'fileForTypedPath' if at all possible.
fileForPath :: FilePath  -> File
fileForPath p = File p (languageForFilePath p)

fileForTypedPath :: Path.PartClass.AbsRel ar => Path.File ar -> File
fileForTypedPath = fileForPath . Path.toString

-- | The source, path information, and language of a file read from disk.
data Blob = Blob
  { blobSource :: Source -- ^ The UTF-8 encoded source text of the blob.
  , blobFile   :: File   -- ^ Path/language information for this blob.
  , blobOid    :: Text   -- ^ Git OID for this blob, mempty if blob is not from a git db.
  } deriving (Show, Eq)

blobLanguage :: Blob -> Language
blobLanguage = fileLanguage . blobFile

blobPath :: Blob -> FilePath
blobPath = filePath . blobFile

makeBlob :: Source -> FilePath -> Language -> Text -> Blob
makeBlob s p l = Blob s (File p l)
{-# INLINE makeBlob #-}

newtype Blobs a = Blobs { blobs :: [a] }
  deriving (Generic, FromJSON)

instance FromJSON Blob where
  parseJSON = withObject "Blob" $ \b -> inferringLanguage
    <$> b .: "content"
    <*> b .: "path"
    <*> b .: "language"

nullBlob :: Blob -> Bool
nullBlob Blob{..} = Source.null blobSource

sourceBlob :: FilePath -> Language -> Source -> Blob
sourceBlob filepath language source = makeBlob source filepath language mempty

inferringLanguage :: Source -> FilePath -> Language -> Blob
inferringLanguage src pth lang
  | knownLanguage lang = makeBlob src pth lang mempty
  | otherwise = makeBlob src pth (languageForFilePath pth) mempty

decodeBlobs :: BL.ByteString -> Either String [Blob]
decodeBlobs = fmap blobs <$> eitherDecode

-- | An exception indicating that we’ve tried to diff or parse a blob of unknown language.
newtype NoLanguageForBlob = NoLanguageForBlob FilePath
  deriving (Eq, Exception, Ord, Show)

noLanguageForBlob :: Has (Error SomeException) sig m => FilePath -> m a
noLanguageForBlob blobPath = throwError (SomeException (NoLanguageForBlob blobPath))

-- | Construct a 'Module' for a 'Blob' and @term@, relative to some root 'FilePath'.
moduleForBlob :: Maybe FilePath -- ^ The root directory relative to which the module will be resolved, if any. TODO: typed paths
              -> Blob             -- ^ The 'Blob' containing the module.
              -> term             -- ^ The @term@ representing the body of the module.
              -> Module term    -- ^ A 'Module' named appropriate for the 'Blob', holding the @term@, and constructed relative to the root 'FilePath', if any.
moduleForBlob rootDir b = Module info
  where root = fromMaybe (FP.takeDirectory (blobPath b)) rootDir
        info = ModuleInfo (FP.makeRelative root (blobPath b)) (languageToText (blobLanguage b)) (blobOid b)

-- | Represents a blobs suitable for diffing which can be either a blob to
-- delete, a blob to insert, or a pair of blobs to diff.
type BlobPair = Edit Blob Blob

instance FromJSON BlobPair where
  parseJSON = withObject "BlobPair" $ \o ->
    fromMaybes <$> (o .:? "before") <*> (o .:? "after")
    >>= maybeM (Prelude.fail "Expected object with 'before' and/or 'after' keys only")

maybeBlobPair :: MonadFail m => Maybe Blob -> Maybe Blob -> m BlobPair
maybeBlobPair a b = maybeM (fail "expected file pair with content on at least one side") (fromMaybes a b)

languageForBlobPair :: BlobPair -> Language
languageForBlobPair = mergeEdit combine . bimap blobLanguage blobLanguage where
  combine a b
    | a == Unknown || b == Unknown = Unknown
    | otherwise                    = b

pathForBlobPair :: BlobPair -> FilePath
pathForBlobPair = blobPath . mergeEdit (const id)

languageTagForBlobPair :: BlobPair -> [(String, String)]
languageTagForBlobPair pair = showLanguage (languageForBlobPair pair)
  where showLanguage = pure . (,) "language" . show

pathKeyForBlobPair :: BlobPair -> FilePath
pathKeyForBlobPair = mergeEdit combine . bimap blobPath blobPath where
   combine before after | before == after = after
                        | otherwise       = before <> " -> " <> after

instance ToJSONFields Blob where
  toJSONFields p = [ "path" .= blobPath p, "language" .= blobLanguage p]

decodeBlobPairs :: BL.ByteString -> Either String [BlobPair]
decodeBlobPairs = fmap blobs <$> eitherDecode
