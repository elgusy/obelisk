{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
module Obelisk.Command.Thunk
  ( ThunkPtr (..)
  , ThunkRev (..)
  , ThunkSource (..)
  , GitHubSource (..)
  , getLatestRev
  , updateThunkToLatest
  , createThunkWithLatest
  ) where

import Control.Exception
import Control.Monad
import qualified Data.ByteString.Lazy as LBS
import Data.Aeson as Aeson
import Data.Aeson.Encode.Pretty
import Data.Foldable
import Data.Git.Ref (Ref)
import qualified Data.Git.Ref as Ref
import Data.Maybe
import Data.Monoid
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as T
import Data.Text.Encoding
import Data.Yaml (parseMaybe, (.:))
import qualified Data.Yaml as Yaml
import GitHub
import GitHub.Endpoints.Repos.Contents (archiveForR)
import GitHub.Data.Name
import Network.URI
import System.Directory
import System.Exit
import System.FilePath
import System.Process

-- | A reference to the exact data that a thunk should translate into
data ThunkPtr = ThunkPtr
  { _thunkPtr_rev :: ThunkRev
  , _thunkPtr_source :: ThunkSource
  }
  deriving (Show, Eq, Ord)

type NixSha256 = Text --TODO: Use a smart constructor and make this actually verify itself

-- | A specific revision of data; it may be available from multiple sources
data ThunkRev = ThunkRev
  { _thunkRev_commit :: Ref
  , _thunkRev_nixSha256 :: NixSha256
  }
  deriving (Show, Eq, Ord)

-- | A location from which a thunk's data can be retrieved
data ThunkSource
   = ThunkSource_GitHub GitHubSource
   deriving (Show, Eq, Ord)

data GitHubSource = GitHubSource
  { _gitHubSource_owner :: Name Owner
  , _gitHubSource_repo :: Name Repo
  , _gitHubSource_branch :: Maybe (Name Branch)
  , _gitHubSource_private :: Bool
  }
  deriving (Show, Eq, Ord)

commitNameToRef :: Name Commit -> Ref
commitNameToRef (N c) = Ref.fromHex $ encodeUtf8 c

getNixSha256ForUriUnpacked :: URI -> IO NixSha256
getNixSha256ForUriUnpacked uri = do
  (_, out, _, p) <- runInteractiveProcess "nix-prefetch-url" --TODO: Make this package depend on nix-prefetch-url properly
    [ "--unpack"
    , "--type"
    , "sha256"
    , show uri
    ] Nothing Nothing
  ExitSuccess <- waitForProcess p --TODO: Deal with errors here; usually they're HTTP errors
  T.strip <$> T.hGetContents out

-- | Get the latest revision available from the given source
getLatestRev :: ThunkSource -> IO ThunkRev
getLatestRev = \case
  ThunkSource_GitHub s -> do
    auth <- getHubAuth "github.com"
    commitsResult <- executeRequestMaybe auth $ commitsWithOptionsForR
      (_gitHubSource_owner s)
      (_gitHubSource_repo s)
      (FetchAtLeast 1)
      $ case _gitHubSource_branch s of
          Nothing -> []
          Just b -> [CommitQuerySha $ untagName b]
    commitInfos <- either throwIO return commitsResult
    commitInfo : _ <- return $ toList commitInfos
    let commit = commitSha commitInfo
    Right archiveUri <- executeRequestMaybe auth $ archiveForR (_gitHubSource_owner s) (_gitHubSource_repo s) ArchiveFormatTarball $ Just $ untagName commit
    nixSha256 <- getNixSha256ForUriUnpacked archiveUri
    return $ ThunkRev
      { _thunkRev_commit = commitNameToRef commit
      , _thunkRev_nixSha256 = nixSha256
      }

-- | Read a thunk and validate that it is only a thunk.  If additional data is
-- present, fail.
readThunk :: FilePath -> IO (Maybe ThunkPtr)
readThunk thunkDir = do
  let githubJson = thunkDir </> "github.json"
  doesFileExist githubJson >>= \case
    False -> return Nothing
    True -> do
      -- Ensure that we recognize the thunk loader
      loader <- T.readFile $ thunkDir </> "default.nix"
      guard $ loader `elem` gitHubStandaloneLoaders

      -- Ensure that there aren't any other files in the thunk
      files <- listDirectory thunkDir
      guard $ length files == 2

      txt <- LBS.readFile githubJson
      let p v = do
            owner <- v Aeson..: "owner"
            repo <- v Aeson..: "repo"
            rev <- v Aeson..: "rev"
            sha256 <- v Aeson..: "sha256"
            branch <- v Aeson..:! "branch"
            mPrivate <- v Aeson..:! "private"
            return $ ThunkPtr
              { _thunkPtr_rev = ThunkRev
                { _thunkRev_commit = Ref.fromHexString rev
                , _thunkRev_nixSha256 = sha256
                }
              , _thunkPtr_source = ThunkSource_GitHub $ GitHubSource
                { _gitHubSource_owner = owner
                , _gitHubSource_repo = repo
                , _gitHubSource_branch = branch
                , _gitHubSource_private = fromMaybe False mPrivate
                }
              }
      return $ parseMaybe p =<< decode txt

overwriteThunk :: FilePath -> ThunkPtr -> IO ()
overwriteThunk target thunk = do
  -- Ensure that this directory is a valid thunk (i.e. so we aren't losing any data)
  Just _ <- readThunk target

  --TODO: Is there a safer way to do this overwriting?
  removeDirectoryRecursive target
  createThunk target thunk

createThunk :: FilePath -> ThunkPtr -> IO ()
createThunk target thunk = do
  createDirectory target
  case _thunkPtr_source thunk of
    ThunkSource_GitHub s -> do
      T.writeFile (target </> "default.nix") $ NonEmpty.head gitHubStandaloneLoaders
      LBS.writeFile (target </> "github.json") $
        -- It's important that formatting be very consistent here, because
        -- otherwise when people update thunks, their patches will be messy
        let cfg = defConfig
              { confIndent = Spaces 2
              , confCompare = keyOrder
                  [ "owner"
                  , "repo"
                  , "branch"
                  , "private"
                  , "rev"
                  , "sha256"
                  ] <> compare
              , confTrailingNewline = True
              }
        in encodePretty' cfg $ Aeson.object $ catMaybes
           [ Just $ "owner" .= _gitHubSource_owner s
           , Just $ "repo" .= _gitHubSource_repo s
           , case _gitHubSource_branch s of
               Just b -> Just $ "branch" .= b
               Nothing -> Nothing
           , if _gitHubSource_private s
             then Just $ "private" .= True
             else Nothing
           , Just $ "rev" .= Ref.toHexString (_thunkRev_commit (_thunkPtr_rev thunk))
           , Just $ "sha256" .= _thunkRev_nixSha256 (_thunkPtr_rev thunk)
           ]

createThunkWithLatest :: FilePath -> ThunkSource -> IO ()
createThunkWithLatest target s = do
  rev <- getLatestRev s
  createThunk target $ ThunkPtr
    { _thunkPtr_source = s
    , _thunkPtr_rev = rev
    }

updateThunkToLatest :: FilePath -> IO ()
updateThunkToLatest target = do
  Just ptr <- readThunk target
  let src = _thunkPtr_source ptr
  rev <- getLatestRev src
  overwriteThunk target $ ThunkPtr
    { _thunkPtr_source = src
    , _thunkPtr_rev = rev
    }

-- | All recognized github standalone loaders, ordered from newest to oldest.
-- This tool will only ever produce the newest one when it writes a thunk.
gitHubStandaloneLoaders :: NonEmpty Text
gitHubStandaloneLoaders =
  gitHubStandaloneLoaderV2 :|
  [ gitHubStandaloneLoaderV1
  ]

gitHubStandaloneLoaderV1 :: Text
gitHubStandaloneLoaderV1 = T.unlines
  [ "import ((import <nixpkgs> {}).fetchFromGitHub (builtins.fromJSON (builtins.readFile ./github.json)))"
  ]

gitHubStandaloneLoaderV2 :: Text
gitHubStandaloneLoaderV2 = T.unlines
  [ "# DO NOT HAND-EDIT THIS FILE" --TODO: Add something about how to get more info on Obelisk, etc.
  , "import ((import <nixpkgs> {}).fetchFromGitHub ("
  , "  let json = builtins.fromJSON (builtins.readFile ./github.json);"
  , "  in { inherit (json) owner repo rev sha256;"
  , "       private = json.private or false;"
  , "     }"
  , "))"
  ]

-- | Look for authentication info from the 'hub' command
getHubAuth
  :: Text -- ^ Domain name
  -> IO (Maybe Auth)
getHubAuth domain = do
  hubConfig <- getXdgDirectory XdgConfig "hub"
  Yaml.decodeFile hubConfig >>= \case
    Nothing -> return Nothing
    Just v -> return $ flip parseMaybe v $ \v' -> do
      Yaml.Array domainConfigs <- v' .: domain --TODO: Determine what multiple domainConfigs means
      [Yaml.Object domainConfig] <- return $ toList domainConfigs
      token <- domainConfig .: "oauth_token"
      return $ OAuth $ encodeUtf8 token

--TODO: when checking something out, make a shallow clone