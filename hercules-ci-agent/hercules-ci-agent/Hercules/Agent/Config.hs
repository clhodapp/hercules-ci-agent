{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE FlexibleInstances #-}
module Hercules.Agent.Config
  ( Config(..)
  , FinalConfig
  , ConfigPath(..)
  , Purpose(..)
  , readConfig
  , finalizeConfig
  )
where

import           Protolude               hiding ( to )
import qualified System.Environment
import           Toml
import qualified System.Directory
import           System.FilePath ((</>))

data ConfigPath = TomlPath FilePath

data Purpose = Input | Final

-- | Whether the 'Final' value is optional.
data Sort = Required | Optional
type family Item purpose sort a where
  Item 'Input _sort a = Maybe a
  Item 'Final 'Required a = a
  Item 'Final 'Optional a = Maybe a

type FinalConfig = Config 'Final
data Config purpose = Config
  { herculesApiBaseURL :: Item purpose 'Required Text
  , concurrentTasks :: Item purpose 'Required Integer

  , baseDirectory :: Item purpose 'Required FilePath

  , staticSecretsDirectory :: Item purpose 'Required FilePath
    -- ^ Read-only

  , workDirectory :: Item purpose 'Required FilePath

  , clusterJoinTokenPath :: Item purpose 'Required FilePath
  , binaryCachesPath :: Item purpose 'Optional FilePath

  } deriving (Generic)
deriving instance Show (Config 'Final)

tomlCodec :: TomlCodec (Config 'Input)
tomlCodec =
  Config
    <$> dioptional (Toml.text "apiBaseUrl")
    .= herculesApiBaseURL
    <*> dioptional (Toml.integer "concurrentTasks")
    .= concurrentTasks
    <*> dioptional (Toml.string keyBaseDirectory)
    .= baseDirectory
    <*> dioptional (Toml.string "staticSecretsDirectory")
    .= staticSecretsDirectory
    <*> dioptional (Toml.string "workDirectory")
    .= workDirectory
    <*> dioptional (Toml.string keyClusterJoinTokenPath)
    .= clusterJoinTokenPath
    <*> dioptional (Toml.string "binaryCachesPath")
    .= binaryCachesPath

keyClusterJoinTokenPath :: Key
keyClusterJoinTokenPath = "clusterJoinTokenPath"

keyBaseDirectory :: Key
keyBaseDirectory = "baseDirectory"

determineDefaultApiBaseUrl :: IO Text
determineDefaultApiBaseUrl = do
  maybeEnv <- System.Environment.lookupEnv "HERCULES_API_BASE_URL"
  pure $ maybe defaultApiBaseUrl toS maybeEnv

defaultApiBaseUrl :: Text
defaultApiBaseUrl = "https://hercules-ci.com"

defaultConcurrentTasks :: Integer
defaultConcurrentTasks = 4

readConfig :: ConfigPath -> IO (Config 'Input)
readConfig loc = case loc of
  TomlPath fp -> Toml.decodeFile tomlCodec (toSL fp)

finalizeConfig :: Config 'Input -> IO (Config 'Final)
finalizeConfig input = do

  baseDir <- case baseDirectory input of
    Just x -> pure x
    Nothing -> throwIO $ FatalError $ "You need to specify " <> show keyBaseDirectory <> " in the configuration file."

  let staticSecretsDir =
        fromMaybe (baseDir </> "secrets") (staticSecretsDirectory input)
      clusterJoinTokenP = fromMaybe
        (staticSecretsDir </> "cluster-join-token.key")
        (clusterJoinTokenPath input)
      
      workDir = fromMaybe (baseDir </> "work") (workDirectory input)

  dabu <- determineDefaultApiBaseUrl

  pure Config
    { herculesApiBaseURL = fromMaybe dabu $ herculesApiBaseURL input
    , binaryCachesPath = binaryCachesPath input
    , clusterJoinTokenPath = clusterJoinTokenP
    , concurrentTasks = fromMaybe defaultConcurrentTasks $ concurrentTasks input
    , baseDirectory = baseDir
    , staticSecretsDirectory = staticSecretsDir
    , workDirectory = workDir
    }
