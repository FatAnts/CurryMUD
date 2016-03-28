{-# OPTIONS_GHC -fno-warn-type-defaults #-}
{-# LANGUAGE LambdaCase, MonadComprehensions, MultiWayIf, NamedFieldPuns, OverloadedStrings, PatternSynonyms, RecordWildCards, ViewPatterns #-}

module Mud.Interp.Login (interpName) where

import Mud.Cmds.Msgs.Misc
import Mud.Cmds.Msgs.Sorry
import Mud.Cmds.Pla
import Mud.Cmds.Util.Misc
import Mud.Data.Misc
import Mud.Data.State.ActionParams.ActionParams
import Mud.Data.State.MsgQueue
import Mud.Data.State.MudData
import Mud.Data.State.Util.Get
import Mud.Data.State.Util.Misc
import Mud.Data.State.Util.Output
import Mud.Interp.Misc
import Mud.Misc.ANSI
import Mud.Misc.Database
import Mud.Misc.Logging hiding (logNotice, logPla)
import Mud.TheWorld.Zones.AdminZoneIds (iCentral, iLoggedOut, iWelcome)
import Mud.Threads.Digester
import Mud.Threads.Effect
import Mud.Threads.Misc
import Mud.Threads.Regen
import Mud.TopLvlDefs.Chars
import Mud.TopLvlDefs.FilePaths
import Mud.TopLvlDefs.Misc
import Mud.TopLvlDefs.Telnet
import Mud.Util.List
import Mud.Util.Misc hiding (patternMatchFail)
import Mud.Util.Operators
import Mud.Util.Quoting
import Mud.Util.Text
import Mud.Util.Wrapping
import qualified Mud.Misc.Logging as L (logNotice, logPla)
import qualified Mud.Util.Misc as U (patternMatchFail)

import Control.Arrow (first)
import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TQueue (writeTQueue)
import Control.Exception.Lifted (try)
import Control.Lens (at, both, views)
import Control.Lens.Operators ((%~), (&), (.~), (^.))
import Control.Monad ((>=>), unless, when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Loops (orM)
import Crypto.BCrypt (validatePassword)
import Data.Bits (setBit, zeroBits)
import Data.Char (isDigit, isLower, isUpper)
import Data.Ix (inRange)
import Data.List (delete, intersperse, partition)
import Data.Maybe (fromJust)
import Data.Monoid ((<>), Any(..))
import Data.Text (Text)
import Data.Time (UTCTime)
import Network (HostName)
import Prelude hiding (pi)
import qualified Data.IntMap.Lazy as IM (foldr, toList)
import qualified Data.Set as S (Set, empty, fromList, insert, member)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Text.IO as T (readFile)


default (Int)


-----


patternMatchFail :: Text -> [Text] -> a
patternMatchFail = U.patternMatchFail "Mud.Interp.Login"


-----


logNotice :: Text -> Text -> MudStack ()
logNotice = L.logNotice "Mud.Interp.Login"


logPla :: Text -> Id -> Text -> MudStack ()
logPla = L.logPla "Mud.Interp.Login"


-- ==================================================


interpName :: Interp
interpName (T.toLower -> cn@(capitalize -> cn')) (NoArgs i mq cols)
  | not . inRange (minNameLen, maxNameLen) . T.length $ cn = promptRetryName mq cols sorryInterpNameLen
  | T.any (`elem` illegalChars) cn                         = promptRetryName mq cols sorryInterpNameIllegal
  | otherwise                                              = getState >>= \ms ->
      case findExistingPlas cn' ms of
        [] -> mIf (orM . map (getAny <$>) $ [ checkProfanitiesDict i  mq cols cn
                                            , checkIllegalNames    ms mq cols cn
                                            , checkPropNamesDict      mq cols cn
                                            , checkWordsDict          mq cols cn
                                            , checkRndmNames          mq cols cn ])
                  unit
                  confirmName
        [(targetId, targetPla)] -> do
            sendPrompt mq $ telnetHideInput <> "Password:"
            setInterp i . Just . interpPW cn' targetId $ targetPla
        (map fst -> xs) -> patternMatchFail "interpName" [ showText xs ]
  where
    illegalChars = [ '!' .. '@' ] ++ [ '[' .. '`' ] ++ [ '{' .. '~' ]
    confirmName  = do
        wrapSendPrompt mq cols $ "Your name will be " <> dblQuote (cn' <> ",") <> " is that OK? [yes/no]"
        setInterp i . Just . interpConfirmName $ cn'
interpName _ ActionParams { .. } = promptRetryName plaMsgQueue plaCols sorryInterpNameExcessArgs


promptRetryName :: MsgQueue -> Cols -> Text -> MudStack ()
promptRetryName mq cols msg = let t = "Let's try this again. By what name are you known?"
                              in (>> wrapSendPrompt mq cols t) $ if ()# msg
                                then send mq . nl $ ""
                                else wrapSend mq cols msg


findExistingPlas :: Sing -> MudState -> [(Id, Pla)]
findExistingPlas s ms = filter ((== s) . (`getSing` ms) . fst) . views plaTbl IM.toList $ ms


-----


checkProfanitiesDict :: Id -> MsgQueue -> Cols -> CmdName -> MudStack Any
checkProfanitiesDict i mq cols cn = checkNameHelper (Just profanitiesFile) "checkProfanitiesDict" sorry cn
  where
    sorry = getState >>= \ms -> do
        wrapSend mq cols . colorWith bootMsgColor $ sorryInterpNameProfanityLogged
        sendMsgBoot mq . Just $ sorryInterpNameProfanityBoot
        -----
        ts <- liftIO mkTimestamp
        let prof = ProfRec ts (T.pack . getCurrHostName i $ ms) cn
        withDbExHandler_ "checkProfanitiesDict sorry" . insertDbTblProf $ prof
        -----
        let msg = T.concat [ "booting ", getSing i ms, " due to profanity." ]
        bcastAdmins (capitalize msg) >> logNotice "checkProfanitiesDict sorry" msg


checkNameHelper :: Maybe FilePath -> Text -> MudStack () -> CmdName -> MudStack Any
checkNameHelper Nothing     _       _     _  = return mempty
checkNameHelper (Just file) funName sorry cn = (liftIO . T.readFile $ file) |&| try >=> either
    (emptied . fileIOExHandler funName)
    (checkSet cn sorry . S.fromList . T.lines . T.toLower)


checkSet :: CmdName -> MudStack () -> S.Set Text -> MudStack Any
checkSet cn sorry set = let isNG = cn `S.member` set in when isNG sorry >> (return . Any $ isNG)


checkIllegalNames :: MudState -> MsgQueue -> Cols -> CmdName -> MudStack Any
checkIllegalNames ms mq cols cn =
    checkSet cn (promptRetryName mq cols sorryInterpNameTaken) . insertEntNames $ insertRaceNames
  where
    insertRaceNames = foldr helper S.empty (allValues :: [Race])
      where
        helper (uncapitalize . showText -> r) acc = foldr S.insert acc . (r :) . map (`T.cons` r) $ "mf"
    insertEntNames = views entTbl (flip (IM.foldr (views entName (maybe id S.insert)))) ms


checkPropNamesDict :: MsgQueue -> Cols -> CmdName -> MudStack Any
checkPropNamesDict mq cols =
    checkNameHelper propNamesFile "checkPropNamesDict" . promptRetryName mq cols $ sorryInterpNamePropName


checkWordsDict :: MsgQueue -> Cols -> CmdName -> MudStack Any
checkWordsDict mq cols = checkNameHelper wordsFile "checkWordsDict" . promptRetryName mq cols $ sorryInterpNameDict


checkRndmNames :: MsgQueue -> Cols -> CmdName -> MudStack Any
checkRndmNames mq cols = checkNameHelper (Just rndmNamesFile) "checkRndmNames" . promptRetryName mq cols $ sorryInterpNameTaken


-- ==================================================


interpConfirmName :: Sing -> Interp
interpConfirmName s cn (NoArgs i mq cols) = getState >>= \ms@(getSing i -> oldSing) -> case yesNoHelper cn of
  Just True -> if ()!# findExistingPlas s ms -- Did someone else take the name before the user could answer "yes"?
    then promptRetryName  mq cols sorryInterpNameTaken >> setInterp i (Just interpName)
    else let msg = T.concat [ oldSing, " is now known as ", s, "." ] in do
        tweak $ entTbl.ind i.sing .~ s
        bcastAdmins msg >> logNotice "interpConfirmName" msg
        sendPrompt mq . T.concat $ [ telnetHideInput
                                   , nlPrefix . multiWrap cols . pwMsg $ "Please choose a password for " <> s <> "."
                                   , "New password:" ]
        setInterp i . Just . interpNewPW oldSing $ s
  Just False -> promptRetryName  mq cols "" >> setInterp i (Just interpName)
  Nothing    -> promptRetryYesNo mq cols
interpConfirmName _ _ ActionParams { plaMsgQueue, plaCols } = promptRetryYesNo plaMsgQueue plaCols


-- ==================================================


interpNewPW :: Sing -> Sing -> Interp
interpNewPW oldSing s cn (NoArgs i mq cols)
  | not . inRange (minNameLen, maxNameLen) . T.length $ cn = promptRetryNewPW mq cols sorryInterpNewPwLen
  | helper isUpper                                         = promptRetryNewPW mq cols sorryInterpNewPwUpper
  | helper isLower                                         = promptRetryNewPW mq cols sorryInterpNewPwLower
  | helper isDigit                                         = promptRetryNewPW mq cols sorryInterpNewPwDigit
  | otherwise = do
      sendPrompt mq "Verify password:"
      setInterp i . Just . interpVerifyNewPW oldSing s $ cn
  where
    helper f = ()# T.filter f cn
interpNewPW _ _ _ ActionParams { plaMsgQueue, plaCols } = promptRetryNewPW plaMsgQueue plaCols sorryInterpNewPwExcessArgs


promptRetryNewPW :: MsgQueue -> Cols -> Text -> MudStack ()
promptRetryNewPW mq cols msg = let t = "Let's try this again. New password:"
                               in (>> wrapSendPrompt mq cols t) $ if ()# msg
                                 then send mq . nl $ ""
                                 else wrapSend mq cols msg


-- ==================================================


interpVerifyNewPW :: Sing -> Sing -> Text -> Interp
interpVerifyNewPW oldSing s pass cn params@(NoArgs i mq cols)
  | cn == pass = do
      withDbExHandler_ "unpw" . insertDbTblUnPw . UnPwRec s $ pass
      send mq telnetShowInput
      helper |&| modifyState >=> \ms@(getPla i -> p) -> do
          wrapSend mq cols pwWarningMsg
          initPlaLog i s
          logPla "interpVerifyNewPW" i $ "new character logged in from " <> views currHostName T.pack p <> "."
          handleLogin oldSing s True params
          notifyQuestion i ms
  | otherwise = promptRetryNewPwMatch mq cols i oldSing s
  where
    helper ms = let ms'  = ms  & invTbl.ind iWelcome   %~ (i `delete`)
                               & mobTbl.ind i.rmId     .~ iCentral
                               & mobTbl.ind i.interp   .~ Nothing
                               & plaTbl.ind i.plaFlags .~ (setBit zeroBits . fromEnum $ IsTunedQuestion)
                    ms'' = ms' & invTbl.ind iCentral   %~ addToInv ms' (pure i)
                in (ms'', ms'')
interpVerifyNewPW oldSing s _ _ ActionParams { .. } = promptRetryNewPwMatch plaMsgQueue plaCols myId oldSing s


promptRetryNewPwMatch :: MsgQueue -> Cols -> Id -> Sing -> Sing -> MudStack ()
promptRetryNewPwMatch mq cols i oldSing s =
    promptRetryNewPW mq cols sorryInterpNewPwMatch >> setInterp i (Just . interpNewPW oldSing $ s)


notifyQuestion :: Id -> MudState -> MudStack ()
notifyQuestion i ms =
    let msg      = f "A new character has arrived in CurryMUD."
        f        = (colorWith arrowColor "<- " <>) . colorWith questionArrivalColor
        tunedIds = uncurry (++) . getTunedQuestionIds i $ ms
    in bcastNl =<< expandEmbeddedIds ms questionChanContext =<< formatQuestion i ms (msg, tunedIds)


-- ==================================================


-- Returning player.
interpPW :: Sing -> Id -> Pla -> Interp
interpPW targetSing targetId targetPla cn params@(WithArgs i mq cols as) = send mq telnetShowInput >> if
  | ()# cn || ()!# as -> sorryHelper sorryInterpPW
  | otherwise         -> getState >>= \ms -> do
      let oldSing = getSing i ms
      (withDbExHandler "interpPW" . liftIO . lookupPW $ targetSing) >>= \case
        Nothing        -> dbError mq cols
        Just (Just pw) -> if uncurry validatePassword ((pw, cn) & both %~ T.encodeUtf8)
          then if isLoggedIn targetPla
            then sorry (sorryInterpPwLoggedIn targetSing) . T.concat $ [ oldSing
                                                                       , " has entered the correct password for "
                                                                       , targetSing
                                                                       , "; however, "
                                                                       , targetSing
                                                                       , " is already logged in." ]
            else (withDbExHandler "interpPW" . isPCBanned $ targetSing) >>= \case
              Nothing          -> dbError mq cols
              Just (Any True ) -> handleBanned    ms oldSing
              Just (Any False) -> handleNotBanned ms oldSing
          else sorry sorryInterpPW . T.concat $ [ oldSing, " has entered an incorrect password for ", targetSing, "." ]
        Just Nothing -> sorryHelper sorryInterpPW
  where
    sorry sorryMsg msg = do
        bcastAdmins msg
        logNotice "interpPW sorry" msg
        sorryHelper sorryMsg
    sorryHelper sorryMsg = do
        liftIO . threadDelay $ 2 * 10 ^ 6
        promptRetryName mq cols sorryMsg
        setInterp i . Just $ interpName
    handleBanned (T.pack . getCurrHostName i -> host) oldSing = do
        let msg  = T.concat [ oldSing
                            , " has been booted at login upon entering the correct password for "
                            , targetSing
                            , " "
                            , parensQuote "player is banned"
                            , "." ]
        sendMsgBoot mq . Just . sorryInterpPwBanned $ targetSing
        bcastAdmins $ msg <> " Consider also banning host " <> dblQuote host <> "."
        logNotice "interpPW handleBanned" msg
    handleNotBanned ((i `getPla`) -> newPla) oldSing =
        let helper ms = dup . logIn i ms (newPla^.currHostName) (newPla^.connectTime) $ targetId
        in helper |&| modifyState >=> \ms -> do
               logNotice "interpPW handleNotBanned" . T.concat $ [ oldSing
                                                                 , " has logged in as "
                                                                 , targetSing
                                                                 , ". Id "
                                                                 , showText targetId
                                                                 , " has been changed to "
                                                                 , showText i
                                                                 , "." ]
               initPlaLog i targetSing
               logPla "interpPW handleNotBanned" i $ "logged in from " <> T.pack (getCurrHostName i ms) <> "."
               handleLogin oldSing targetSing False params { args = [] }
interpPW _ _ _ _ p = patternMatchFail "interpPW" [ showText p ]


logIn :: Id -> MudState -> HostName -> Maybe UTCTime -> Id -> MudState
logIn newId ms newHost newTime originId = peepNewId . movePC $ adoptNewId
  where
    adoptNewId = ms & activeEffectsTbl.ind newId         .~ getActiveEffects originId ms
                    & activeEffectsTbl.at  originId      .~ Nothing
                    & coinsTbl        .ind newId         .~ getCoins         originId ms
                    & coinsTbl        .at  originId      .~ Nothing
                    & entTbl          .ind newId         .~ (getEnt          originId ms & entId .~ newId)
                    & entTbl          .at  originId      .~ Nothing
                    & eqTbl           .ind newId         .~ getEqMap         originId ms
                    & eqTbl           .at  originId      .~ Nothing
                    & invTbl          .ind newId         .~ getInv           originId ms
                    & invTbl          .at  originId      .~ Nothing
                    & mobTbl          .ind newId         .~ getMob           originId ms
                    & mobTbl          .at  originId      .~ Nothing
                    & pausedEffectsTbl.ind newId         .~ getPausedEffects originId ms
                    & pausedEffectsTbl.at  originId      .~ Nothing
                    & pcTbl           .ind newId         .~ getPC            originId ms
                    & pcTbl           .at  originId      .~ Nothing
                    & plaTbl          .ind newId         .~ (getPla          originId ms & currHostName .~ newHost
                                                                                         & connectTime  .~ newTime)
                    & plaTbl          .ind newId.peepers .~ getPeepers       originId ms
                    & plaTbl          .at  originId      .~ Nothing
                    & rndmNamesMstrTbl.ind newId         .~ getRndmNamesTbl  originId ms
                    & rndmNamesMstrTbl.at  originId      .~ Nothing
                    & teleLinkMstrTbl .ind newId         .~ getTeleLinkTbl   originId ms
                    & teleLinkMstrTbl .at  originId      .~ Nothing
                    & typeTbl         .at  originId      .~ Nothing
    movePC ms' = let newRmId = fromJust . getLastRmId newId $ ms'
                 in ms' & invTbl  .ind iWelcome       %~ (newId    `delete`)
                        & invTbl  .ind iLoggedOut     %~ (originId `delete`)
                        & invTbl  .ind newRmId        %~ addToInv ms' (pure newId)
                        & mobTbl  .ind newId.rmId     .~ newRmId
                        & plaTbl  .ind newId.lastRmId .~ Nothing
    peepNewId ms'@(getPeepers newId -> peeperIds) =
        let replaceId = (newId :) . (originId `delete`)
        in ms' & plaTbl %~ flip (foldr (\peeperId -> ind peeperId.peeping %~ replaceId)) peeperIds


handleLogin :: Sing -> Sing -> Bool -> ActionParams -> MudStack ()
handleLogin oldSing s isNew params@ActionParams { .. } = do
    greet
    showMotd plaMsgQueue plaCols
    (ms, p) <- showRetainedMsgs
    look params
    sendDfltPrompt plaMsgQueue myId
    when (getPlaFlag IsAdmin p) stopInacTimer
    runDigesterAsync     myId
    runRegenAsync        myId
    restartPausedEffects myId
    notifyArrival ms
  where
    greet = wrapSend plaMsgQueue plaCols . nlPrefix $ if | s == "Root" -> colorWith zingColor sudoMsg
                                                         | isNew       -> "Welcome to CurryMUD, " <> s <> "!"
                                                         | otherwise   -> "Welcome back, " <> s <> "!"
    showRetainedMsgs = helper |&| modifyState >=> \(ms, msgs, p) -> do
        unless (()# msgs) $ do
            let (fromPpl, others) = first (map T.tail) . partition ((== fromPersonMarker) . T.head) $ msgs
            others  |#| multiWrapSend plaMsgQueue plaCols . intersperse ""
            fromPpl |#| let m   = "message" <> case fromPpl of [_] -> ""
                                                               _   -> "s"
                            msg = "You missed the following " <> m <> " while you were away:"
                        in multiWrapSend plaMsgQueue plaCols . (msg :)
            logPla "handleLogin showRetainedMsgs" myId "showed retained messages."
        return (ms, p)
    helper ms = let p   = getPla myId ms
                    p'  = p  & retainedMsgs    .~ []
                    ms' = ms & plaTbl.ind myId .~ p'
                in (ms', (ms', p^.retainedMsgs, p'))
    stopInacTimer = do
        liftIO . atomically . writeTQueue plaMsgQueue $ InacStop
        logPla "handleLogin stopInacTimer" myId "stopping the inactivity timer."
    notifyArrival ms = do
        bcastOtherAdmins myId $ if isNew
          then T.concat [ s, " has arrived in CurryMUD ", parensQuote ("was " <> oldSing), "." ]
          else T.concat [ oldSing, " has logged in as ", s, "." ]
        bcastOthersInRm  myId . nlnl . notifyArrivalMsg . mkSerializedNonStdDesig myId ms s A $ DoCap
