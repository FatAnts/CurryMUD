{-# LANGUAGE FlexibleContexts, LambdaCase, MonadComprehensions, MultiWayIf, OverloadedStrings, PatternSynonyms, RankNTypes, RecordWildCards, TupleSections, ViewPatterns #-}

-- This module contains helper functions used by multiple functions in "Mud.Cmds.Pla", as well as helper functions used
-- by both "Mud.Cmds.Pla" and "Mud.Cmds.ExpCmds".

module Mud.Cmds.Util.Pla ( armSubToSlot
                         , bugTypoLogger
                         , checkMutuallyTuned
                         , clothToSlot
                         , donMsgs
                         , execIfPossessed
                         , fillerToSpcs
                         , findAvailSlot
                         , genericAction
                         , getMatchingChanWithName
                         , getRelativePCName
                         , hasFp
                         , hasHp
                         , hasMp
                         , hasPp
                         , helperDropEitherInv
                         , helperGetDropEitherCoins
                         , helperGetEitherInv
                         , helperLinkUnlink
                         , helperPutRemEitherCoins
                         , helperPutRemEitherInv
                         , inOutOnOffs
                         , InvWithCon
                         , IsConInRm
                         , isNonStdLink
                         , isRingRol
                         , isRndmName
                         , isSlotAvail
                         , linkDirToCmdName
                         , maybeSingleSlot
                         , mkChanBindings
                         , mkChanNamesTunings
                         , mkCoinsDesc
                         , mkCoinsSummary
                         , mkEntDescs
                         , mkEqDesc
                         , mkExitsSummary
                         , mkInvCoinsDesc
                         , mkLastArgWithNubbedOthers
                         , mkMaybeNthOfM
                         , mkPutRemoveBindings
                         , mkReadyMsgs
                         , moveReadiedItem
                         , notFoundSuggestAsleeps
                         , otherHand
                         , putOnMsgs
                         , resolveMobInvCoins
                         , resolveRmInvCoins ) where

import Mud.Cmds.Msgs.Dude
import Mud.Cmds.Msgs.Misc
import Mud.Cmds.Msgs.Sorry
import Mud.Cmds.Util.Abbrev
import Mud.Cmds.Util.Misc
import Mud.Data.Misc
import Mud.Data.State.ActionParams.ActionParams
import Mud.Data.State.MsgQueue
import Mud.Data.State.MudData
import Mud.Data.State.Util.Calc
import Mud.Data.State.Util.Coins
import Mud.Data.State.Util.Get
import Mud.Data.State.Util.Misc
import Mud.Data.State.Util.Output
import Mud.Misc.ANSI
import Mud.Misc.Database
import Mud.Misc.NameResolution
import Mud.TopLvlDefs.Chars
import Mud.TopLvlDefs.Misc
import Mud.TopLvlDefs.Padding
import Mud.Util.List
import Mud.Util.Misc hiding (patternMatchFail)
import Mud.Util.Operators
import Mud.Util.Padding
import Mud.Util.Quoting
import Mud.Util.Text
import Mud.Util.Wrapping
import Prelude hiding (pi)
import qualified Mud.Misc.Logging as L (logPla, logPlaOut)
import qualified Mud.Util.Misc as U (patternMatchFail)

import Control.Arrow ((***), first)
import Control.Lens (Getter, _1, _2, _3, _4, _5, at, both, each, to, view, views)
import Control.Lens.Operators ((%~), (&), (.~), (<>~), (?~), (^.))
import Control.Monad ((>=>), guard)
import Control.Monad.IO.Class (liftIO)
import Data.Char (isLower)
import Data.Function (on)
import Data.List ((\\), delete, elemIndex, find, foldl', intercalate, nub, sortBy)
import Data.Maybe (catMaybes, fromJust)
import Data.Monoid ((<>), Sum(..))
import Data.Text (Text)
import qualified Data.IntMap.Lazy as IM (keys)
import qualified Data.Map.Lazy as M ((!), notMember, toList)
import qualified Data.Text as T


{-# ANN module ("HLint: ignore Use camelCase" :: String) #-}


-----


patternMatchFail :: Text -> [Text] -> a
patternMatchFail = U.patternMatchFail "Mud.Cmds.Util.Pla"


-----


logPla :: Text -> Id -> Text -> MudStack ()
logPla = L.logPla "Mud.Cmds.Util.Pla"


logPlaOut :: Text -> Id -> [Text] -> MudStack ()
logPlaOut = L.logPlaOut "Mud.Cmds.Util.Pla"


-- ==================================================


armSubToSlot :: ArmSub -> Slot
armSubToSlot = \case Head      -> HeadS
                     Torso     -> TorsoS
                     Arms      -> ArmsS
                     Hands     -> HandsS
                     LowerBody -> LowerBodyS
                     Feet      -> FeetS
                     Shield    -> undefined


-----


bugTypoLogger :: ActionParams -> WhichLog -> MudStack ()
bugTypoLogger (Msg' i mq msg) wl = getState >>= \ms ->
    let s     = getSing i  ms
        ri    = getRmId i  ms
        mkLoc = parensQuote (showText ri) <> " " <> getRm ri ms ^.rmName
    in liftIO mkTimestamp >>= \ts -> do
        sequence_ $ case wl of BugLog  -> let b = BugRec ts s mkLoc msg True
                                          in [ withDbExHandler_ "bugTypoLogger" . insertDbTblBug $ b
                                             , bcastOtherAdmins i $ s <> " has logged a bug: "  <> pp b ]
                               TypoLog -> let t = TypoRec ts s mkLoc msg True
                                          in [ withDbExHandler_ "bugTypoLogger" . insertDbTblTypo $ t
                                             , bcastOtherAdmins i $ s <> " has logged a typo: " <> pp t ]
        send mq . nlnl $ "Thank you."
        logPla "bugTypoLogger" i . T.concat $ [ "logged a ", showText wl, ": ", msg ]
bugTypoLogger p wl = patternMatchFail "bugTypoLogger" [ showText p, showText wl ]


-----


checkMutuallyTuned :: Id -> MudState -> Sing -> Either Text Id
checkMutuallyTuned i ms targetSing = case areMutuallyTuned of
  (False, _,    _       ) -> Left . sorryTunedOutPCSelf $ targetSing
  (True,  False, _      ) -> Left . (effortsBlockedMsg <>) . sorryTunedOutPCTarget $ targetSing
  (True,  True, targetId) -> Right targetId
  where
    areMutuallyTuned | targetId <- getIdForMobSing targetSing ms
                     , a <- (M.! targetSing) . getTeleLinkTbl i        $ ms
                     , b <- (M.! s         ) . getTeleLinkTbl targetId $ ms
                     = (a, b, targetId)
    s                = getSing i ms


-----


clothToSlot :: Cloth -> Slot
clothToSlot = \case Shirt    -> ShirtS
                    Smock    -> SmockS
                    Coat     -> CoatS
                    Trousers -> TrousersS
                    Skirt    -> SkirtS
                    Dress    -> DressS
                    FullBody -> FullBodyS
                    Backpack -> BackpackS
                    Cloak    -> CloakS
                    _        -> undefined


-----


donMsgs :: Id -> Desig -> Sing -> (Text, Broadcast)
donMsgs = mkReadyMsgs "don" "dons"


type SndPerVerb = Text
type ThrPerVerb = Text


mkReadyMsgs :: SndPerVerb -> ThrPerVerb -> Id -> Desig -> Sing -> (Text, Broadcast)
mkReadyMsgs spv tpv i d s = (  T.concat [ "You ", spv, " the ", s, "." ]
                            , (T.concat [ serialize d, spaced tpv, aOrAn s, "." ], i `delete` desigIds d) )


-----


execIfPossessed :: ActionParams -> CmdName -> ActionFun -> MudStack ()
execIfPossessed p@(WithArgs i mq cols _) cn f = getState >>= \ms ->
    let s = getSing i ms in case getPossessor i ms of
      Nothing -> wrapSend mq cols (sorryNotPossessed s cn)
      Just _  -> f p
execIfPossessed p cn _ = patternMatchFail "execIfPossessed" [ showText p, cn ]


-----


fillerToSpcs :: Text -> Text
fillerToSpcs = T.replace (T.singleton indentFiller) " "


-----


genericAction :: ActionParams
              -> (MudState -> (MudState, ([Text], [Broadcast], [Text])))
              -> Text
              -> MudStack ()
genericAction ActionParams { .. } helper fn = helper |&| modifyState >=> \(toSelfs, bs, logMsgs) -> do
    ms <- getState
    multiWrapSend plaMsgQueue plaCols [ parseDesig myId ms msg | msg <- toSelfs ]
    bcastIfNotIncogNl myId bs
    logMsgs |#| logPlaOut fn myId


-----


getMatchingChanWithName :: Text -> [ChanName] -> [Chan] -> (ChanName, Chan)
getMatchingChanWithName match cns cs = let cn  = head . filter ((== match) . T.toLower) $ cns
                                           c   = head . filter (views chanName (== cn)) $ cs
                                       in (cn, c)


-----


getRelativePCName :: MudState -> (Id, Id) -> MudStack Text
getRelativePCName ms pair@(_, y)
  | isLinked ms pair = return . getSing y $ ms
  | otherwise        = underline <$> uncurry updateRndmName pair


-----


hasHp :: Id -> MudState -> Int -> Bool
hasHp = hasPoints curHp


hasMp :: Id -> MudState -> Int -> Bool
hasMp = hasPoints curMp


hasPp :: Id -> MudState -> Int -> Bool
hasPp = hasPoints curPp


hasFp :: Id -> MudState -> Int -> Bool
hasFp = hasPoints curFp


hasPoints :: Getter Mob Int -> Id -> MudState -> Int -> Bool
hasPoints lens i ms amt = views (mobTbl.ind i.lens) (>= amt) ms


-----


type FromId = Id
type ToId   = Id


helperDropEitherInv :: Id
                    -> Desig
                    -> FromId
                    -> ToId
                    -> (MudState, [Text], [Broadcast])
                    -> Either Text Inv
                    -> (MudState, [Text], [Broadcast])
helperDropEitherInv i d fi ti a@(ms, _, _) = \case
  Left  msg -> a & _2 <>~ pure msg
  Right is  -> let (toSelfs, bs) = mkGetDropInvDescs i ms d Drop is
               in a & _1.invTbl.ind fi %~  (\\ is)
                    & _1.invTbl.ind ti %~  (sortInv ms . (++ is))
                    & _2               <>~ toSelfs
                    & _3               <>~ bs


mkGetDropInvDescs :: Id -> MudState -> Desig -> GetOrDrop -> Inv -> ([Text], [Broadcast])
mkGetDropInvDescs i ms d god (mkNameCountBothList i ms -> ncbs) = unzip . map helper $ ncbs
  where
    helper (_, c, (s, _)) | c == 1 =
        (  T.concat [ "You ",               mkGodVerb god SndPer, " the ", s, "." ]
        , (T.concat [ serialize d, spaced . mkGodVerb god $ ThrPer, aOrAn s,  "." ], otherIds) )
    helper (_, c, b) =
        (  T.concat [ "You ",           mkGodVerb god SndPer, rest ]
        , (T.concat [ serialize d, " ", mkGodVerb god ThrPer, rest ], otherIds) )
      where
        rest = spaced (showText c) <> mkPlurFromBoth b <> "."
    otherIds = i `delete` desigIds d


mkNameCountBothList :: Id -> MudState -> Inv -> [(Text, Int, BothGramNos)]
mkNameCountBothList i ms targetIds = let ens   = [ getEffName        i ms targetId | targetId <- targetIds ]
                                         cs    = mkCountList ebgns
                                         ebgns = [ getEffBothGramNos i ms targetId | targetId <- targetIds ]
                                     in nub . zip3 ens cs $ ebgns


mkGodVerb :: GetOrDrop -> Verb -> Text
mkGodVerb Get  SndPer = "pick up"
mkGodVerb Get  ThrPer = "picks up"
mkGodVerb Drop SndPer = "drop"
mkGodVerb Drop ThrPer = "drops"


-----


helperGetDropEitherCoins :: Id
                         -> Desig
                         -> GetOrDrop
                         -> FromId
                         -> ToId
                         -> (MudState, [Text], [Broadcast], [Text])
                         -> [Either [Text] Coins]
                         -> (MudState, [Text], [Broadcast], [Text])
helperGetDropEitherCoins i d god fi ti (ms, toSelfs, bs, logMsgs) ecs =
    let (ms', toSelfs', logMsgs', canCoins) = foldl' helper (ms, toSelfs, logMsgs, mempty) ecs
    in (ms', toSelfs', bs ++ mkGetDropCoinsDescOthers i d god canCoins, logMsgs')
  where
    helper a = \case
      Left  msgs -> a & _2 <>~ msgs
      Right c    -> let (can, can't) = case god of Get  -> partitionByEnc c
                                                   Drop -> (c, mempty)
                        toSelfs'     = mkGetDropCoinsDescsSelf god can
                    in a & _1.coinsTbl.ind fi %~  (<> negateCoins can)
                         & _1.coinsTbl.ind ti %~  (<>             can)
                         & _2                 <>~ toSelfs' ++ mkCan'tGetCoinsDesc can't
                         & _3                 <>~ toSelfs'
                         & _4                 <>~ can
      where
        partitionByEnc c = let maxEnc           = calcMaxEnc i ms
                               w                = calcWeight i ms
                               noOfCoins        = sum . coinsToList $ c
                               totalCoinsWeight = noOfCoins * coinWeight
                           in if w + totalCoinsWeight <= maxEnc
                             then (c, mempty)
                             else let availWeight  = maxEnc - w
                                      canNoOfCoins = availWeight `quot` coinWeight
                                  in mkCanCan't c canNoOfCoins
        mkCanCan't (Coins (c, 0, 0)) n = (Coins (n, 0, 0), Coins (c - n, 0,     0    ))
        mkCanCan't (Coins (0, s, 0)) n = (Coins (0, n, 0), Coins (0,     s - n, 0    ))
        mkCanCan't (Coins (0, 0, g)) n = (Coins (0, 0, n), Coins (0,     0,     g - n))
        mkCanCan't c                 n = patternMatchFail "helperGetDropEitherCoins mkCanCan't" [ showText c
                                                                                                , showText n ]


mkGetDropCoinsDescOthers :: Id -> Desig -> GetOrDrop -> Coins -> [Broadcast]
mkGetDropCoinsDescOthers i d god c =
  c |!| [ (T.concat [ serialize d, spaced . mkGodVerb god $ ThrPer, aCoinSomeCoins c, "." ], i `delete` desigIds d) ]


mkGetDropCoinsDescsSelf :: GetOrDrop -> Coins -> [Text]
mkGetDropCoinsDescsSelf god = mkCoinsMsgs helper
  where
    helper 1 cn = T.concat [ "You ", mkGodVerb god SndPer, " ", aOrAn cn,             "."  ]
    helper a cn = T.concat [ "You ", mkGodVerb god SndPer, spaced . showText $ a, cn, "s." ]


mkCoinsMsgs :: (Int -> Text -> Text) -> Coins -> [Text]
mkCoinsMsgs f (Coins (cop, sil, gol)) = catMaybes [ c, s, g ]
  where
    c = Sum cop |!| Just . f cop $ "copper piece"
    s = Sum sil |!| Just . f sil $ "silver piece"
    g = Sum gol |!| Just . f gol $ "gold piece"


mkCan'tGetCoinsDesc :: Coins -> [Text]
mkCan'tGetCoinsDesc = mkCoinsMsgs helper
  where
    helper a cn = sorryGetEnc <> (a == 1 ? ("the " <> cn <> ".") :? T.concat [ showText a, " ", cn, "s." ])


-----


helperGetEitherInv :: Id
                   -> Desig
                   -> FromId
                   -> ToId
                   -> (MudState, [Text], [Broadcast], [Text])
                   -> Either Text Inv
                   -> (MudState, [Text], [Broadcast], [Text])
helperGetEitherInv i d fi ti a@(ms, _, _, _) = \case
  Left  msg                              -> a & _2 <>~ pure msg
  Right (sortByType -> (npcPCs, others)) ->
    let (_, cans, can'ts) = foldl' (partitionByEnc (calcMaxEnc i ms)) (calcWeight i ms, [], []) others
        (toSelfs, bs    ) = mkGetDropInvDescs i ms d Get cans
    in a & _1.invTbl.ind fi %~  (\\ cans)
         & _1.invTbl.ind ti %~  (sortInv ms . (++ cans))
         & _2               <>~ concat [ map sorryType npcPCs
                                       , toSelfs
                                       , mkCan'tGetInvDescs i ms can'ts ]
         & _3               <>~ bs
         & _4               <>~ toSelfs
  where
    sortByType             = foldr helper ([], [])
    helper targetId sorted = let lens = case getType targetId ms of PCType  -> _1
                                                                    NpcType -> _1
                                                                    _       -> _2
                             in sorted & lens %~ (targetId :)
    partitionByEnc maxEnc acc@(w, _, _) targetId = let w' = w + calcWeight targetId ms in
        w' <= maxEnc ? (acc & _1 .~ w' & _2 <>~ pure targetId) :? (acc & _3 <>~ pure targetId)
    sorryType targetId = sorryGetType . serialize . mkStdDesig targetId ms $ Don'tCap


mkCan'tGetInvDescs :: Id -> MudState -> Inv -> [Text]
mkCan'tGetInvDescs i ms = map helper . mkNameCountBothList i ms
  where
    helper (_, c, b@(s, _)) = sorryGetEnc <> (c == 1 ?  ("the " <> s <> ".")
                                                     :? T.concat [ showText c, " ", mkPlurFromBoth b, "." ])


-----


helperLinkUnlink :: MudState -> Id -> MsgQueue -> Cols -> MudStack (Maybe ([Text], [Text], [Text]))
helperLinkUnlink ms i mq cols =
    let s                = getSing   i ms
        othersLinkedToMe = getLinked i ms
        meLinkedToOthers = foldr buildSingList [] $ i `delete` (ms^.pcTbl.to IM.keys)
        buildSingList pi acc | s `elem` getLinked pi ms = getSing pi ms : acc
                             | otherwise                = acc
        twoWays = map fst . filter ((== 2) . snd) . countOccs $ othersLinkedToMe ++ meLinkedToOthers
    in if all (()#) [ othersLinkedToMe, meLinkedToOthers ]
      then emptied $ wrapSend mq cols sorryNoLinks >> (logPlaOut "helperLinkUnlink" i . pure $ sorryNoLinks)
      else unadulterated (meLinkedToOthers, othersLinkedToMe, twoWays)


-----


type NthOfM = (Int, Int)
type ToSing = Sing


-- TODO: Check for encumbrance when a player removes coins from a container in the room.
helperPutRemEitherCoins :: Id
                        -> Desig
                        -> PutOrRem
                        -> Maybe NthOfM
                        -> FromId
                        -> ToId
                        -> ToSing
                        -> (CoinsTbl, [Text], [Broadcast], [Text])
                        -> [Either [Text] Coins]
                        -> (CoinsTbl, [Text], [Broadcast], [Text])
helperPutRemEitherCoins i d por mnom fi ti ts (ct, toSelfs, bs, logMsgs) ecs =
    let (ct', toSelfs', logMsgs', canCoins) = foldl' helper (ct, toSelfs, logMsgs, mempty) ecs
    in (ct', toSelfs', bs ++ mkPutRemCoinsDescOthers i d por mnom canCoins ts, logMsgs')
  where
    helper a = \case
      Left  msgs -> a & _2 <>~ msgs
      Right c    -> let toSelfs' = mkPutRemCoinsDescsSelf por mnom c ts
                    in a & _1.ind fi %~ (<> negateCoins c)
                         & _1.ind ti %~ (<> c)
                         & _2 <>~ toSelfs' -- TODO: Append a "can't remove coins" message. See "helperGetDropEitherCoins".
                         & _3 <>~ toSelfs'
                         & _4 <>~ c


mkPutRemCoinsDescOthers :: Id -> Desig -> PutOrRem -> Maybe NthOfM -> Coins -> ToSing -> [Broadcast]
mkPutRemCoinsDescOthers i d por mnom c ts = c |!| [ ( T.concat [ serialize d
                                                               , spaced . mkPorVerb por $ ThrPer
                                                               , aCoinSomeCoins c
                                                               , " "
                                                               , mkPorPrep por ThrPer mnom ts
                                                               , onTheGround mnom <> "." ]
                                                    , i `delete` desigIds d ) ]


mkPutRemCoinsDescsSelf :: PutOrRem -> Maybe NthOfM -> Coins -> ToSing -> [Text]
mkPutRemCoinsDescsSelf por mnom c ts = mkCoinsMsgs helper c
  where
    helper a cn | a == 1 = T.concat [ start, aOrAn cn,   " ",           rest ]
    helper a cn          = T.concat [ start, showText a, " ", cn, "s ", rest ]
    start                = "You " <> mkPorVerb por SndPer <> " "
    rest                 = mkPorPrep por SndPer mnom ts <> onTheGround mnom <> "."


mkPorVerb :: PutOrRem -> Verb -> Text
mkPorVerb Put SndPer = "put"
mkPorVerb Put ThrPer = "puts"
mkPorVerb Rem SndPer = "remove"
mkPorVerb Rem ThrPer = "removes"


mkPorPrep :: PutOrRem -> Verb -> Maybe NthOfM -> Sing -> Text
mkPorPrep Put SndPer Nothing       = ("in the "   <>)
mkPorPrep Put SndPer (Just (n, m)) = ("in the "   <>) . (descNthOfM n m <>)
mkPorPrep Rem SndPer Nothing       = ("from the " <>)
mkPorPrep Rem SndPer (Just (n, m)) = ("from the " <>) . (descNthOfM n m <>)
mkPorPrep Put ThrPer Nothing       = ("in "       <>) . aOrAn
mkPorPrep Put ThrPer (Just (n, m)) = ("in the "   <>) . (descNthOfM n m <>)
mkPorPrep Rem ThrPer Nothing       = ("from "     <>) . aOrAn
mkPorPrep Rem ThrPer (Just (n, m)) = ("from the " <>) . (descNthOfM n m <>)


descNthOfM :: Int -> Int -> Text
descNthOfM 1 1 = ""
descNthOfM n _ = mkOrdinal n <> " "


onTheGround :: Maybe NthOfM -> Text
onTheGround = (|!| " on the ground") . ((both %~ Sum) <$>)


-----


-- TODO: Check for encumbrance when a player removes something from a container in the room.
helperPutRemEitherInv :: Id
                      -> MudState
                      -> Desig
                      -> PutOrRem
                      -> Maybe NthOfM
                      -> FromId
                      -> ToId
                      -> ToSing
                      -> (InvTbl, [Text], [Broadcast], [Text])
                      -> Either Text Inv
                      -> (InvTbl, [Text], [Broadcast], [Text])
helperPutRemEitherInv i ms d por mnom fi ti ts a = \case
  Left  msg -> a & _2 <>~ pure msg
  Right is  -> let (is', toSelfs) = onTrue (ti `elem` is) f (is, view _2 a)
                   f pair         = pair & _1 %~  filter (/= ti)
                                         & _2 <>~ (pure . sorryPutInsideSelf $ ts)
                   (toSelfs', bs) = mkPutRemInvDescs i ms d por mnom is' ts
               in ()# (a^._1.ind fi) ? sorry :? (a & _1.ind fi %~  (\\ is')
                                                   & _1.ind ti %~  (sortInv ms . (++ is'))
                                                   & _2        .~  (toSelfs ++ toSelfs')
                                                   & _3        <>~ bs
                                                   & _4        <>~ toSelfs')
  where
    sorry = a & _2 <>~ (pure . sorryRemEmpty . getSing fi $ ms)


mkPutRemInvDescs :: Id -> MudState -> Desig -> PutOrRem -> Maybe NthOfM -> Inv -> ToSing -> ([Text], [Broadcast])
mkPutRemInvDescs i ms d por mnom is ts = unzip . map helper . mkNameCountBothList i ms $ is
  where
    helper (_, c, (s, _)) | c == 1 =
        (  T.concat [ "You "
                    , mkPorVerb por SndPer
                    , spaced withArticle
                    , mkPorPrep por SndPer mnom ts
                    , rest ]
        , (T.concat [ serialize d
                    , spaced . mkPorVerb por $ ThrPer
                    , aOrAn s
                    , " "
                    , mkPorPrep por ThrPer mnom ts
                    , rest ], otherIds) )
      where
        withArticle = por == Put ? "the " <> s :? aOrAn s
    helper (_, c, b) =
        (  T.concat [ "You "
                    , mkPorVerb por SndPer
                    , spaced . showText $ c
                    , mkPlurFromBoth b
                    , " "
                    , mkPorPrep por SndPer mnom ts
                    , rest ]
        , (T.concat [ serialize d
                    , spaced . mkPorVerb por $ ThrPer
                    , showText c
                    , spaced . mkPlurFromBoth $ b
                    , mkPorPrep por ThrPer mnom ts
                    , rest ], otherIds) )
    rest     = onTheGround mnom <> "."
    otherIds = i `delete` desigIds d


-----


inOutOnOffs :: [(Text, Bool)]
inOutOnOffs = [ ("i",   otherwise)
              , ("in",  otherwise)
              , ("o",   likewise )
              , ("of",  likewise )
              , ("off", likewise )
              , ("on",  otherwise)
              , ("ou",  likewise )
              , ("out", likewise ) ]


-----


isRingRol :: RightOrLeft -> Bool
isRingRol = \case R -> False
                  L -> False
                  _ -> True


-----


isRndmName :: Text -> Bool
isRndmName = isLower . T.head . dropANSI


-----


isSlotAvail :: EqMap -> Slot -> Bool
isSlotAvail = flip M.notMember


findAvailSlot :: EqMap -> [Slot] -> Maybe Slot
findAvailSlot em = find (isSlotAvail em)


-----


maybeSingleSlot :: EqMap -> Slot -> Maybe Slot
maybeSingleSlot em s = boolToMaybe (isSlotAvail em s) s


-----


mkChanBindings :: Id -> MudState -> ([Chan], [ChanName], Sing)
mkChanBindings i ms = let cs  = getPCChans i ms
                          cns = map (view chanName) cs
                          s   = getSing i ms
                      in (cs, cns, s)


-----


mkChanNamesTunings :: Id -> MudState -> ([Text], [Bool])
mkChanNamesTunings i ms = unzip . sortBy (compare `on` fst) . map helper . getPCChans i $ ms
  where
    helper = (view chanName *** views chanConnTbl (M.! getSing i ms)) . dup


-----


mkCoinsDesc :: Cols -> Coins -> Text
mkCoinsDesc cols (Coins (each %~ Sum -> (cop, sil, gol))) =
    T.unlines . intercalate [""] . map (wrap cols) . dropEmpties $ [ cop |!| copDesc
                                                                   , sil |!| silDesc
                                                                   , gol |!| golDesc ]
  where
    copDesc = "The copper piece is round and shiny."
    silDesc = "The silver piece is round and shiny."
    golDesc = "The gold piece is round and shiny."


-----


mkEntDescs :: Id -> Cols -> MudState -> Inv -> Text
mkEntDescs i cols ms eis = T.intercalate "\n" [ mkEntDesc i cols ms (ei, e) | ei <- eis, let e = getEnt ei ms ]


mkEntDesc :: Id -> Cols -> MudState -> (Id, Ent) -> Text
mkEntDesc i cols ms (ei, e) | ed <- views entDesc (wrapUnlines cols) e, s <- getSing ei ms, t <- getType ei ms =
    case t of ConType ->                 (ed <>) . mkInvCoinsDesc i cols ms ei $ s
              NpcType ->                 (ed <>) . mkEqDesc       i cols ms ei   s $ t
              PCType  -> (pcHeader <>) . (ed <>) . mkEqDesc       i cols ms ei   s $ t
              _       -> ed
  where
    pcHeader = wrapUnlines cols mkPCDescHeader
    mkPCDescHeader | (pp *** pp -> (s, r)) <- getSexRace ei ms = T.concat [ "You see a ", s, " ", r, "." ]


mkInvCoinsDesc :: Id -> Cols -> MudState -> Id -> Sing -> Text
mkInvCoinsDesc i cols ms targetId targetSing | targetInv <- getInv targetId ms, targetCoins <- getCoins targetId ms =
    case ((()#) *** (()#)) (targetInv, targetCoins) of
      (True,  True ) -> wrapUnlines cols (targetId == i ? dudeYourHandsAreEmpty :? "The " <> targetSing <> " is empty.")
      (False, True ) -> header <> mkEntsInInvDesc i cols ms targetInv                                    <> footer
      (True,  False) -> header                                        <> mkCoinsSummary cols targetCoins <> footer
      (False, False) -> header <> mkEntsInInvDesc i cols ms targetInv <> mkCoinsSummary cols targetCoins <> footer
  where
    header = targetId == i ? nl "You are carrying:" :? wrapUnlines cols ("The " <> targetSing <> " contains:")
    footer = targetId == i |?| nl $ (showText . calcEncPer i $ ms) <> "% encumbered."


mkEntsInInvDesc :: Id -> Cols -> MudState -> Inv -> Text
mkEntsInInvDesc i cols ms =
    T.unlines . concatMap (wrapIndent entNamePadding cols . helper) . mkStyledName_Count_BothList i ms
  where
    helper (padEntName -> en, c, (s, _)) | c == 1 = en <> "1 " <> s
    helper (padEntName -> en, c, b     )          = T.concat [ en, showText c, " ", mkPlurFromBoth b ]


mkStyledName_Count_BothList :: Id -> MudState -> Inv -> [(Text, Int, BothGramNos)]
mkStyledName_Count_BothList i ms is =
    let styleds                       = styleAbbrevs DoQuote [ getEffName        i ms targetId | targetId <- is ]
        boths@(mkCountList -> counts) =                      [ getEffBothGramNos i ms targetId | targetId <- is ]
    in nub . zip3 styleds counts $ boths


mkCoinsSummary :: Cols -> Coins -> Text
mkCoinsSummary cols c = helper . zipWith mkNameAmt coinNames . coinsToList $ c
  where
    helper         = T.unlines . wrapIndent 2 cols . commas . filter (()!#)
    mkNameAmt cn a = Sum a |!| showText a <> " " <> bracketQuote (colorWith abbrevColor cn)


mkEqDesc :: Id -> Cols -> MudState -> Id -> Sing -> Type -> Text
mkEqDesc i cols ms descId descSing descType = let descs = descId == i ? mkDescsSelf :? mkDescsOther in
    ()# descs ? noDescs :? ((header <>) . T.unlines . concatMap (wrapIndent 15 cols) $ descs)
  where
    mkDescsSelf =
        let (slotNames,  es ) = unzip [ (pp slot, getEnt ei ms)          | (slot, ei) <- M.toList . getEqMap i $ ms ]
            (sings,      ens) = unzip [ (e^.sing, fromJust $ e^.entName) | e          <- es                         ]
        in map helper . zip3 slotNames sings . styleAbbrevs DoQuote $ ens
      where
        helper (T.breakOn " finger" -> (slotName, _), s, styled) = T.concat [ parensPad 15 slotName, s, " ", styled ]
    mkDescsOther = map helper [ (pp slot, getSing ei ms) | (slot, ei) <- M.toList . getEqMap descId $ ms ]
      where
        helper (T.breakOn " finger" -> (slotName, _), s) = parensPad 15 slotName <> s
    noDescs = wrapUnlines cols $ if
      | descId   == i      -> dudeYou'reNaked
      | descType == PCType -> parseDesig i ms $ d  <> " doesn't have anything readied."
      | otherwise          -> theOnLowerCap descSing <> " doesn't have anything readied."
    header = wrapUnlines cols $ if
      | descId   == i      -> "You have readied the following equipment:"
      | descType == PCType -> parseDesig i ms $ d  <> " has readied the following equipment:"
      | otherwise          -> theOnLowerCap descSing <> " has readied the following equipment:"
    d = mkSerializedNonStdDesig descId ms descSing The DoCap


-----


mkExitsSummary :: Cols -> Rm -> Text
mkExitsSummary cols (view rmLinks -> rls) =
    let stdNames    = [ rl^.linkDir .to (colorWith exitsColor . linkDirToCmdName) | rl <- rls, not . isNonStdLink $ rl ]
        customNames = [ rl^.linkName.to (colorWith exitsColor                   ) | rl <- rls,       isNonStdLink   rl ]
    in T.unlines . wrapIndent 2 cols . ("Obvious exits: " <>) . summarize stdNames $ customNames
  where
    summarize []  []  = "None!"
    summarize std cus = commas . (std ++) $ cus


linkDirToCmdName :: LinkDir -> CmdName
linkDirToCmdName North     = "n"
linkDirToCmdName Northeast = "ne"
linkDirToCmdName East      = "e"
linkDirToCmdName Southeast = "se"
linkDirToCmdName South     = "s"
linkDirToCmdName Southwest = "sw"
linkDirToCmdName West      = "w"
linkDirToCmdName Northwest = "nw"
linkDirToCmdName Up        = "u"
linkDirToCmdName Down      = "d"


isNonStdLink :: RmLink -> Bool
isNonStdLink NonStdLink {} = True
isNonStdLink _             = False


-----


type IsConInRm  = Bool
type InvWithCon = Inv


mkMaybeNthOfM :: MudState -> IsConInRm -> Id -> Sing -> InvWithCon -> Maybe NthOfM
mkMaybeNthOfM ms icir conId conSing invWithCon = guard icir >> return helper
  where
    helper  = (succ . fromJust . elemIndex conId *** length) . dup $ matches
    matches = filter ((== conSing) . flip getSing ms) invWithCon


-----


mkLastArgWithNubbedOthers :: Args -> (Text, Args)
mkLastArgWithNubbedOthers as = let lastArg = last as
                                   otherArgs = init $ case as of
                                     [_, _] -> as
                                     _      -> (++ pure lastArg) . nub . init $ as
                               in (lastArg, otherArgs)


-----


mkPutRemoveBindings :: Id -> MudState -> Args -> (Desig, (Inv, Coins), (Inv, Coins), ConName, Args)
mkPutRemoveBindings i ms as = let d                 = mkStdDesig  i ms DoCap
                                  pcInvCoins        = getInvCoins i ms
                                  rmInvCoins        = first (i `delete`) . getMobRmNonIncogInvCoins i $ ms
                                  (conName, others) = mkLastArgWithNubbedOthers as
                              in (d, pcInvCoins, rmInvCoins, conName, others)


-----


moveReadiedItem :: Id
                -> (EqTbl, InvTbl, [Text], [Broadcast], [Text])
                -> Slot
                -> Id
                -> (Text, Broadcast)
                -> (EqTbl, InvTbl, [Text], [Broadcast], [Text])
moveReadiedItem i a s targetId (msg, b) = a & _1.ind i.at s ?~ targetId
                                            & _2.ind i %~ (targetId `delete`)
                                            & _3 <>~ pure msg
                                            & _4 <>~ pure b
                                            & _5 <>~ pure msg


-----


notFoundSuggestAsleeps :: Text -> [Sing] -> MudState -> Text
notFoundSuggestAsleeps a@(capitalize . T.toLower -> a') asleepSings ms =
    case findFullNameForAbbrev a' asleepSings of
      Just asleepTarget ->
          let (heShe, _, _) = mkPros . getSex (getIdForMobSing asleepTarget ms) $ ms
              guess         = a' /= asleepTarget |?| ("Perhaps you mean " <> asleepTarget <> "? ")
          in T.concat [ guess
                      , "Unfortunately, "
                      , ()# guess ? asleepTarget :? heShe
                      , " is sleeping at the moment..." ]
      Nothing -> sorryTwoWayLink a


-----


otherHand :: Hand -> Hand
otherHand RHand  = LHand
otherHand LHand  = RHand
otherHand NoHand = LHand


-----


putOnMsgs :: Id -> Desig -> Sing -> (Text, Broadcast)
putOnMsgs = mkReadyMsgs "put on" "puts on"


-----


resolveMobInvCoins :: Id -> MudState -> Args -> Inv -> Coins -> ([Either Text Inv], [Either [Text] Coins])
resolveMobInvCoins i ms = resolveHelper i ms procGecrMisMobInv procReconciledCoinsMobInv


resolveHelper :: Id
              -> MudState
              -> ((GetEntsCoinsRes, Maybe Inv) -> Either Text Inv)
              -> (ReconciledCoins -> Either [Text] Coins)
              -> Args
              -> Inv
              -> Coins
              -> ([Either Text Inv], [Either [Text] Coins])
resolveHelper i ms f g as is c | (gecrs, miss, rcs) <- resolveEntCoinNames i ms as is c
                               , eiss               <- zipWith (curry f) gecrs miss
                               , ecs                <- map g rcs = (eiss, ecs)


resolveRmInvCoins :: Id -> MudState -> Args -> Inv -> Coins -> ([Either Text Inv], [Either [Text] Coins])
resolveRmInvCoins i ms = resolveHelper i ms procGecrMisRm procReconciledCoinsRm
