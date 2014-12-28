{-# OPTIONS_GHC -funbox-strict-fields -Wall -Werror #-}
{-# LANGUAGE OverloadedStrings, RecordWildCards, ViewPatterns #-}

module Mud.Data.State.Util.Output ( bcast
                                  , bcastNl
                                  , bcastOthersInRm
                                  , expandPCEntName
                                  , frame
                                  , massMsg
                                  , massSend
                                  , mkBroadcast
                                  , mkDividerTxt
                                  , mkNTBroadcast
                                  , multiWrapSend
                                  , ok
                                  , parsePCDesig
                                  , prompt
                                  , send
                                  , sendMsgBoot
                                  , wrapSend ) where

import Mud.Data.Misc
import Mud.Data.State.State
import Mud.Data.State.Util.Misc
import Mud.Data.State.Util.STM
import Mud.TopLvlDefs.Chars
import Mud.TopLvlDefs.Msgs
import Mud.Util hiding (patternMatchFail)
import qualified Mud.Util as U (patternMatchFail)

import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TMVar (putTMVar)
import Control.Concurrent.STM.TQueue (writeTQueue)
import Control.Lens.Getter (view)
import Control.Lens.Operators ((^.))
import Control.Monad (forM_)
import Control.Monad.IO.Class (liftIO)
import Data.IntMap.Lazy ((!))
import Data.List (delete, elemIndex, nub)
import Data.Maybe (fromJust, fromMaybe)
import Data.Monoid ((<>))
import Prelude hiding (pi)
import qualified Data.IntMap.Lazy as IM (elems, keys)
import qualified Data.Text as T


patternMatchFail :: T.Text -> [T.Text] -> a
patternMatchFail = U.patternMatchFail "Mud.Data.State.Util.Output"


-- ============================================================


prompt :: MsgQueue -> T.Text -> MudStack ()
prompt mq = liftIO . atomically . writeTQueue mq . Prompt


send :: MsgQueue -> T.Text -> MudStack ()
send mq = liftIO . atomically . writeTQueue mq . FromServer


wrapSend :: MsgQueue -> Cols -> T.Text -> MudStack ()
wrapSend mq cols = send mq . wrapUnlinesNl cols


multiWrapSend :: MsgQueue -> Cols -> [T.Text] -> MudStack ()
multiWrapSend mq cols = send mq . multiWrapNl cols


sendMsgBoot :: MsgQueue -> Maybe T.Text -> MudStack ()
sendMsgBoot mq = liftIO . atomically . writeTQueue mq . MsgBoot . fromMaybe dfltBootMsg


-- TODO: I wonder if this can/should be refactored?
bcast :: [Broadcast] -> MudStack ()
bcast bs = getMqtPt >>= \(mqt, pt) -> do
    let helper msg i | mq <- mqt ! i, cols <- (pt ! i)^.columns = readWSTMVar >>= \ws ->
          send mq . T.unlines . concatMap (wordWrap cols) . T.lines . parsePCDesig i ws $ msg
    forM_ bs $ \(msg, is) -> mapM_ (helper msg) is


parsePCDesig :: Id -> WorldState -> T.Text -> T.Text
parsePCDesig i ws | (view introduced -> intros) <- (ws^.pcTbl) ! i = helper intros
  where
    helper intros msg
      | T.singleton stdDesigDelimiter `T.isInfixOf` msg
      , (left, pcd, rest) <- extractPCDesigTxt stdDesigDelimiter msg
      = case pcd of
        StdDesig { stdPCEntSing = Just pes, .. } ->
          left <>
          (if pes `elem` intros then pes else expandPCEntName i ws isCap pcEntName pcId pcIds) <>
          helper intros rest
        StdDesig { stdPCEntSing = Nothing,  .. } ->
          left <> expandPCEntName i ws isCap pcEntName pcId pcIds <> helper intros rest
        _                                        -> patternMatchFail "parsePCDesig helper" [ showText pcd ]
      | T.singleton nonStdDesigDelimiter `T.isInfixOf` msg
      , (left, NonStdDesig { .. }, rest) <- extractPCDesigTxt nonStdDesigDelimiter msg
      = left <> (if nonStdPCEntSing `elem` intros then nonStdPCEntSing else nonStdDesc) <> helper intros rest
      | otherwise = msg
    extractPCDesigTxt c (T.span (/= c) -> (left, T.span (/= c) . T.tail -> (pcdTxt, T.tail -> rest)))
      | pcd <- deserialize . quoteWith (T.singleton c) $ pcdTxt :: PCDesig = (left, pcd, rest)


expandPCEntName :: Id -> WorldState -> Bool -> T.Text -> Id -> Inv -> T.Text
expandPCEntName i ws ic pen@(headTail' -> (h, t)) pi ((i `delete`) -> pis) =
    T.concat [ leading, "he ", xth, expandSex h, " ", t ]
  where
    leading | ic        = "T"
            | otherwise = "t"
    xth = let matches = foldr (\i' acc -> if mkUnknownPCEntName i' ws == pen then i' : acc else acc) [] pis
          in case matches of [_] -> ""
                             _   -> (<> " ") . mkOrdinal . (+ 1) . fromJust . elemIndex pi $ matches
    expandSex 'm'                  = "male"
    expandSex 'f'                  = "female"
    expandSex (T.singleton -> x) = patternMatchFail "expandPCEntName expandSex" [x]


bcastNl :: [Broadcast] -> MudStack ()
bcastNl bs = bcast . (bs ++) . concat $ [ mkBroadcast i "\n" | i <- nub . concatMap snd $ bs ]


mkBroadcast :: Id -> T.Text -> [Broadcast]
mkBroadcast i msg = [(msg, [i])]


mkNTBroadcast :: Id -> T.Text -> [ClassifiedBroadcast]
mkNTBroadcast i msg = [NonTargetBroadcast (msg, [i])]


bcastOthersInRm :: Id -> T.Text -> MudStack ()
bcastOthersInRm i msg = bcast =<< helper
  where
    helper = onWS $ \(t, ws) ->
        let (view rmId    -> ri)  = (ws^.pcTbl)  ! i
            ((i `delete`) -> ris) = (ws^.invTbl) ! ri
        in putTMVar t ws >> return [(msg, findPCIds ws ris)]


massMsg :: Msg -> MudStack ()
massMsg m = readTMVarInNWS msgQueueTblTMVar >>= \(IM.elems -> is) ->
    forM_ is $ liftIO . atomically . flip writeTQueue m


massSend :: T.Text -> MudStack ()
massSend msg = getMqtPt >>= \(mqt, pt) -> do
    let helper i = let mq   = mqt ! i
                       cols = (pt ! i)^.columns
                   in send mq . nl' . frame cols . wrapUnlines cols $ msg
    forM_ (IM.keys pt) helper


frame :: Cols -> T.Text -> T.Text
frame cols | divider <- nl . mkDividerTxt $ cols = nl . (<> divider) . (divider <>)


mkDividerTxt :: Cols -> T.Text
mkDividerTxt = flip T.replicate "="


ok :: MsgQueue -> MudStack ()
ok mq = send mq . nlnl $ "OK!"