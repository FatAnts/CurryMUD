{-# OPTIONS_GHC -funbox-strict-fields -Wall -Werror #-}
{-# LANGUAGE FlexibleContexts, LambdaCase, OverloadedStrings, RankNTypes #-}

{-
Copyright 2014 Jason Stolaruk and Detroit Labs LLC

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
-}

module Mud.Logging ( closeLogs
                   , closePlaLog
                   , initLogging
                   , initPlaLog
                   , logAndDispIOEx
                   , logError
                   , logExMsg
                   , logIOEx
                   , logIOExRethrow
                   , logNotice
                   , logPla ) where

import Mud.MiscDataTypes
import Mud.StateDataTypes
import Mud.StateHelpers
import Mud.TopLvlDefs
import Mud.Util

import Control.Concurrent.Async (async, waitBoth)
import Control.Concurrent.STM.TQueue (newTQueueIO, readTQueue, writeTQueue)
import Control.Exception (IOException, SomeException)
import Control.Exception.Lifted (throwIO)
import Control.Lens (at)
import Control.Lens.Operators ((&), (.=), (?~))
import Control.Monad (forM_, void)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.STM (atomically)
import Data.Functor ((<$>))
import Data.Maybe (fromJust)
import Data.Monoid ((<>))
import System.Log (Priority(..))
import System.Log.Formatter (simpleLogFormatter)
import System.Log.Handler (close, setFormatter)
import System.Log.Handler.Simple (fileHandler)
import System.Log.Logger (errorM, infoM, noticeM, setHandlers, setLevel, updateGlobalLogger)
import qualified Data.Text as T


closeLogs :: MudStack ()
closeLogs = do
    logNotice "Mud.Logging" "closeLogs" "closing the logs"
    [ (na, nq), (ea, eq) ] <- sequence [ fromJust <$> getLog noticeLog, fromJust <$> getLog errorLog ]
    forM_ [ nq, eq ] stopLog
    liftIO . void . waitBoth na $ ea


stopLog :: LogQueue -> MudStack ()
stopLog = liftIO . atomically . flip writeTQueue Stop


initLogging :: MudStack ()
initLogging = do
    nq <- liftIO newTQueueIO
    eq <- liftIO newTQueueIO
    na <- liftIO . spawnLogger "notice.log" NOTICE "currymud.notice" noticeM $ nq
    ea <- liftIO . spawnLogger "error.log"  ERROR  "currymud.error"  errorM  $ eq
    nonWorldState.logServices.noticeLog .= Just (na, nq)
    nonWorldState.logServices.errorLog  .= Just (ea, eq)


type LogName    = String
type LoggingFun = String -> String -> IO ()


spawnLogger :: FilePath -> Priority -> LogName -> LoggingFun -> LogQueue -> IO LogAsync
spawnLogger fn p ln f q = async . loop =<< initLog
  where
    initLog = do
        gh <- fileHandler (logDir ++ fn) p
        let h = setFormatter gh . simpleLogFormatter $ "[$time $loggername] $msg"
        updateGlobalLogger ln (setHandlers [h] . setLevel p)
        return gh
    loop gh = (atomically . readTQueue $ q) >>= \case
      Stop  -> close gh
      Msg m -> f ln m >> loop gh


registerMsg :: String -> LogQueue -> MudStack ()
registerMsg msg q = liftIO . atomically . writeTQueue q . Msg $ msg


logNotice :: String -> String -> String -> MudStack ()
logNotice modName funName msg = maybeVoid helper =<< getLog noticeLog
  where
    helper = registerMsg (concat [ modName, " ", funName, ": ", msg, "." ]) . snd


logError :: String -> MudStack ()
logError msg = maybeVoid (registerMsg msg . snd) =<< getLog errorLog


logExMsg :: String -> String -> String -> SomeException -> MudStack ()
logExMsg modName funName msg e = logError . concat $ [ modName, " ", funName, ": ", msg, ". ", dblQuoteStr . show $ e ]


logIOEx :: String -> String -> IOException -> MudStack ()
logIOEx modName funName e = logError . concat $ [ modName, " ", funName, ": ", dblQuoteStr . show $ e ]


logAndDispIOEx :: MsgQueue -> Cols -> String -> String -> IOException -> MudStack ()
logAndDispIOEx mq cols modName funName e = let msg = concat [ modName, " ", funName, ": ", dblQuoteStr . show $ e ]
                                           in logError msg >> (send mq . nl . T.unlines . wordWrap cols . T.pack $ msg)


logIOExRethrow :: String -> String -> IOException -> MudStack ()
logIOExRethrow modName funName e = do
    logError . concat $ [ modName, " ", funName, ": unexpected exception; rethrowing." ]
    liftIO . throwIO $ e


initPlaLog :: Id -> Sing -> MudStack ()
initPlaLog i n = do
    q <- liftIO newTQueueIO
    a <- liftIO . spawnLogger (T.unpack $ n <> ".log") INFO (T.unpack $ "currymud." <> n) infoM $ q
    modifyNWS plaLogsTblTMVar $ \plt -> plt & at i ?~ (a, q)


logPla :: String -> String -> Id -> String -> MudStack ()
logPla modName funName i msg = helper =<< getPlaLogQueue i
  where
    helper = registerMsg (concat [ modName, " ", funName, ": ", msg, "." ])


closePlaLog :: Id -> MudStack ()
closePlaLog i = stopLog =<< getPlaLogQueue i
