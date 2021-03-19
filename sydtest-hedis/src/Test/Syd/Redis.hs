{-# LANGUAGE DataKinds #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeOperators #-}
{-# OPTIONS_GHC -fno-warn-deprecations #-}

-- TODO possibly supply a variant of 'redisSpec' that uses a different database scope per test
-- so that the tests can still happen in parallel:
-- see https://hackage.haskell.org/package/hedis-0.14.2/docs/Database-Redis.html#v:select
-- and connectDatabase:
-- https://hackage.haskell.org/package/hedis-0.14.2/docs/Database-Redis.html#t:ConnectInfo
module Test.Syd.Redis where

import Control.Exception
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Database.Redis as Redis
import Network.Socket
import Network.Socket.Free
import qualified Network.Socket.Wait as Socket
import Path
import Path.IO
import System.Process.Typed
import Test.Syd
import Test.Syd.Path
import Test.Syd.Process.Typed

data RedisServerHandle = RedisServerHandle
  { redisServerHandleProcessHandle :: !(Process () () ()),
    redisServerHandlePort :: !PortNumber
  }

redisSpec :: TestDefM (RedisServerHandle ': outers) Redis.Connection result -> TestDefM outers () result
redisSpec = redisServerSpec . setupAroundWith' redisConnectionSetupFunc

redisConnectionSetupFunc :: RedisServerHandle -> SetupFunc () Redis.Connection
redisConnectionSetupFunc RedisServerHandle {..} = do
  let connInfo = Redis.defaultConnectInfo {connectPort = PortNumber redisServerHandlePort}
  conn <- unwrapSetupFunc checkedConnectSetupFunc connInfo
  makeSimpleSetupFunc $ \func -> do
    errOrStatus <- runRedis conn Redis.flushall -- Clean state
    case errOrStatus of
      Left err -> expectationFailure $ "Something went wrong while trying to clean the state before the test starts: " <> show err
      Right s -> s `shouldBe` Ok
    func conn

checkedConnectSetupFunc :: SetupFunc Redis.ConnectInfo Redis.Connection
checkedConnectSetupFunc = SetupFunc $ \func connInfo -> bracket (checkedConnect connInfo) disconnect func

redisServerSpec :: TestDefM (RedisServerHandle ': outers) inner result -> TestDefM outers inner result
redisServerSpec = setupAroundAll redisServerSetupFunc . sequential -- Must run sequentially because state is shared.

redisServerSetupFunc :: SetupFunc () RedisServerHandle
redisServerSetupFunc = do
  td <- tempDirSetupFunc "sydtest-hedis"
  unwrapSetupFunc redisServerSetupFunc' td

redisServerSetupFunc' :: SetupFunc (Path Abs Dir) RedisServerHandle
redisServerSetupFunc' = wrapSetupFunc $ \td -> do
  pidFile <- resolveFile td "redis.pid"
  logFile <- resolveFile td "redis.log"
  portInt <- liftIO $ do
    (portInt, _socket) <- openFreePort
    close _socket
    pure portInt
  let pn = fromIntegral portInt -- (hopefully) safe because it came from 'getFreePort'.
  let configFileContents =
        T.pack $
          unlines
            [ unwords ["port", show (fromIntegral pn :: Int)],
              unwords ["pidfile", fromAbsFile pidFile],
              unwords ["always-show-logo", "no"], -- No need to see the logo.
              unwords ["logfile", fromAbsFile logFile]
            ]
  configFile <- tempBinaryFileWithContentsSetupFunc "config-file" (TE.encodeUtf8 configFileContents)
  let pc =
        setWorkingDir (fromAbsDir td) $
          setStdout inherit $
            setStderr inherit $
              proc
                "redis-server"
                [fromAbsFile configFile]
  ph <- typedProcessSetupFunc pc
  liftIO $ Socket.wait "127.0.0.1" portInt
  pure $
    RedisServerHandle
      { redisServerHandleProcessHandle = ph,
        redisServerHandlePort = pn
      }
