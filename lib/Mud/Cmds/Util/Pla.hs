{-# OPTIONS_GHC -funbox-strict-fields -Wall -Werror #-}
{-# LANGUAGE LambdaCase, MultiWayIf, OverloadedStrings, ParallelListComp, ViewPatterns #-}

module Mud.Cmds.Util.Pla ( InvWithCon
                         , IsConInRm
                         , dudeYou'reNaked
                         , dudeYourHandsAreEmpty
                         , findAvailSlot
                         , helperGetDropEitherCoins
                         , helperGetDropEitherInv
                         , helperPutRemEitherCoins
                         , helperPutRemEitherInv
                         , isNonStdLink
                         , isRingRol
                         , isSlotAvail
                         , linkDirToCmdName
                         , mkCapStdDesig
                         , mkCoinsDesc
                         , mkCoinsSummary
                         , mkDropReadyBindings
                         , mkEntDescs
                         , mkEqDesc
                         , mkExitsSummary
                         , mkGetDropCoinsDesc
                         , mkGetDropInvDesc
                         , mkGetLookBindings
                         , mkInvCoinsDesc
                         , mkMaybeNthOfM
                         , mkPutRemBindings
                         , mkPutRemCoinsDescs
                         , mkPutRemInvDesc
                         , mkSerializedNonStdDesig
                         , mkStdDesig
                         , mkStyledNameCountBothList
                         , moveReadiedItem
                         , otherHand
                         , resolvePCInvCoins
                         , resolveRmInvCoins ) where

import Mud.ANSI
import Mud.Cmds.Util.Abbrev
import Mud.Data.Misc
import Mud.Data.State.State
import Mud.Data.State.Util.Coins
import Mud.Data.State.Util.Misc
import Mud.Data.State.Util.Output
import Mud.NameResolution
import Mud.TopLvlDefs.Misc
import Mud.Util.Misc
import Mud.Util.Padding
import Mud.Util.Quoting
import Mud.Util.Wrapping

import Control.Arrow ((***))
import Control.Lens (_1, _2, _3, at, both, over, to)
import Control.Lens.Getter (view, views)
import Control.Lens.Operators ((&), (?~), (^.))
import Control.Lens.Setter (set)
import Data.IntMap.Lazy ((!))
import Data.List ((\\), delete, elemIndex, find, intercalate, nub)
import Data.Maybe (catMaybes, fromJust, isNothing)
import Data.Monoid ((<>), mempty)
import qualified Data.Map.Lazy as M (toList)
import qualified Data.Text as T


{-# ANN module ("HLint: ignore Use camelCase" :: String) #-}


-- ==================================================


findAvailSlot :: EqMap -> [Slot] -> Maybe Slot
findAvailSlot em = find (isSlotAvail em)


isSlotAvail :: EqMap -> Slot -> Bool
isSlotAvail em s = em^.at s.to isNothing


-----


type FromId = Id
type ToId   = Id


helperGetDropEitherCoins :: Id                                  ->
                            PCDesig                             ->
                            GetOrDrop                           ->
                            FromId                              ->
                            ToId                                ->
                            (WorldState, [Broadcast], [T.Text]) ->
                            Either [T.Text] Coins               ->
                            (WorldState, [Broadcast], [T.Text])
helperGetDropEitherCoins i d god fi ti a@(ws, _, _) = \case
  Left  msgs -> over _2 (++ [ (msg, [i]) | msg <- msgs ]) a
  Right c | (fc, tc)      <- over both ((ws^.coinsTbl) !) (fi, ti)
          , ws'           <- ws & coinsTbl.at fi ?~ fc <> negateCoins c
                                & coinsTbl.at ti ?~ tc <> c
          , (bs, logMsgs) <- mkGetDropCoinsDesc i d god c
          -> set _1 ws' . over _2 (++ bs) . over _3 (++ logMsgs) $ a


mkGetDropCoinsDesc :: Id -> PCDesig -> GetOrDrop -> Coins -> ([Broadcast], [T.Text])
mkGetDropCoinsDesc i d god c | bs <- mkCoinsBroadcasts c helper = (bs, extractLogMsgs i bs)
  where
    helper a cn | a == 1 =
        [ (T.concat [ "You ",           mkGodVerb god SndPer, " a ", cn, "." ], [i])
        , (T.concat [ serialize d, " ", mkGodVerb god ThrPer, " a ", cn, "." ], otherPCIds) ]
    helper a cn =
        [ (T.concat [ "You ",           mkGodVerb god SndPer, " ", showText a, " ", cn, "s." ], [i])
        , (T.concat [ serialize d, " ", mkGodVerb god ThrPer, " ", showText a, " ", cn, "s." ], otherPCIds) ]
    otherPCIds = i `delete` pcIds d


mkCoinsBroadcasts :: Coins -> (Int -> T.Text -> [Broadcast]) -> [Broadcast]
mkCoinsBroadcasts (Coins (cop, sil, gol)) f = concat . catMaybes $ [ c, s, g ]
  where
    c = if cop /= 0 then Just . f cop $ "copper piece" else Nothing
    s = if sil /= 0 then Just . f sil $ "silver piece" else Nothing
    g = if gol /= 0 then Just . f gol $ "gold piece"   else Nothing


extractLogMsgs :: Id -> [Broadcast] -> [T.Text]
extractLogMsgs i bs = [ fst b | b <- bs, snd b == [i] ]


mkGodVerb :: GetOrDrop -> Verb -> T.Text
mkGodVerb Get  SndPer = "pick up"
mkGodVerb Get  ThrPer = "picks up"
mkGodVerb Drop SndPer = "drop"
mkGodVerb Drop ThrPer = "drops"


-----


helperGetDropEitherInv :: Id                                  ->
                          PCDesig                             ->
                          GetOrDrop                           ->
                          FromId                              ->
                          ToId                                ->
                          (WorldState, [Broadcast], [T.Text]) ->
                          Either T.Text Inv                   ->
                          (WorldState, [Broadcast], [T.Text])
helperGetDropEitherInv i d god fi ti a@(ws, _, _) = \case
  Left  (mkBroadcast i -> b) -> over _2 (++ b) a
  Right is | (fis, tis)      <- over both ((ws^.invTbl) !) (fi, ti)
           , ws'             <- ws & invTbl.at fi ?~ fis \\ is
                                   & invTbl.at ti ?~ sortInv ws (tis ++ is)
           , (bs', logMsgs') <- mkGetDropInvDesc i ws' d god is
           -> set _1 ws' . over _2 (++ bs') . over _3 (++ logMsgs') $ a


mkGetDropInvDesc :: Id -> WorldState -> PCDesig -> GetOrDrop -> Inv -> ([Broadcast], [T.Text])
mkGetDropInvDesc i ws d god (mkNameCountBothList i ws -> ncbs) | bs <- concatMap helper ncbs = (bs, extractLogMsgs i bs)
  where
    helper (_, c, (s, _))
      | c == 1 = [ (T.concat [ "You ",           mkGodVerb god SndPer, " the ", s, "." ], [i])
                 , (T.concat [ serialize d, " ", mkGodVerb god ThrPer, " a ",   s, "." ], otherPCIds) ]
    helper (_, c, b) =
        [ (T.concat [ "You ",           mkGodVerb god SndPer, rest ], [i])
        , (T.concat [ serialize d, " ", mkGodVerb god ThrPer, rest ], otherPCIds) ]
      where
        rest = T.concat [ " ", showText c, " ", mkPlurFromBoth b, "." ]
    otherPCIds = i `delete` pcIds d


mkNameCountBothList :: Id -> WorldState -> Inv -> [(T.Text, Int, BothGramNos)]
mkNameCountBothList i ws is | ens   <- [ getEffName        i ws i' | i' <- is ]
                            , ebgns <- [ getEffBothGramNos i ws i' | i' <- is ]
                            , cs    <- mkCountList ebgns = nub . zip3 ens cs $ ebgns


-----


type NthOfM = (Int, Int)
type ToEnt  = Ent


helperPutRemEitherCoins :: Id                                  ->
                           PCDesig                             ->
                           PutOrRem                            ->
                           Maybe NthOfM                        ->
                           FromId                              ->
                           ToId                                ->
                           ToEnt                               ->
                           (WorldState, [Broadcast], [T.Text]) ->
                           Either [T.Text] Coins               ->
                           (WorldState, [Broadcast], [T.Text])
helperPutRemEitherCoins i d por mnom fi ti te a@(ws, _, _) = \case
  Left  msgs -> over _2 (++ [ (msg, [i]) | msg <- msgs ]) a
  Right c | (fc, tc)      <- over both ((ws^.coinsTbl) !) (fi, ti)
          , ws'           <- ws & coinsTbl.at fi ?~ fc <> negateCoins c
                                & coinsTbl.at ti ?~ tc <> c
          , (bs, logMsgs) <- mkPutRemCoinsDescs i d por mnom c te
          -> set _1 ws' . over _2 (++ bs) . over _3 (++ logMsgs) $ a


mkPutRemCoinsDescs :: Id -> PCDesig -> PutOrRem -> Maybe NthOfM -> Coins -> ToEnt -> ([Broadcast], [T.Text])
mkPutRemCoinsDescs i d por mnom c (view sing -> ts) | bs <- mkCoinsBroadcasts c helper = (bs, extractLogMsgs i bs)
  where
    helper a cn | a == 1 =
        [ (T.concat [ "You "
                    , mkPorVerb por SndPer
                    , " a "
                    , cn
                    , " "
                    , mkPorPrep por SndPer mnom
                    , rest ], [i])
        , (T.concat [ serialize d
                    , " "
                    , mkPorVerb por ThrPer
                    , " a "
                    , cn
                    , " "
                    , mkPorPrep por ThrPer mnom
                    , rest ], otherPCIds) ]
    helper a cn =
        [ (T.concat [ "You "
                    , mkPorVerb por SndPer
                    , " "
                    , showText a
                    , " "
                    , cn
                    , "s "
                    , mkPorPrep por SndPer mnom
                    , rest ], [i])
        , (T.concat [ serialize d
                    , " "
                    , mkPorVerb por ThrPer
                    , " "
                    , showText a
                    , " "
                    , cn
                    , "s "
                    , mkPorPrep por ThrPer mnom
                    , rest ], otherPCIds) ]
    rest       = T.concat [ " ", ts, onTheGround mnom, "." ]
    otherPCIds = i `delete` pcIds d


mkPorVerb :: PutOrRem -> Verb -> T.Text
mkPorVerb Put SndPer = "put"
mkPorVerb Put ThrPer = "puts"
mkPorVerb Rem SndPer = "remove"
mkPorVerb Rem ThrPer = "removes"


mkPorPrep :: PutOrRem -> Verb -> Maybe NthOfM -> T.Text
mkPorPrep Put SndPer Nothing       = "in the"
mkPorPrep Put SndPer (Just (n, m)) = "in the"   <> descNthOfM n m
mkPorPrep Rem SndPer Nothing       = "from the"
mkPorPrep Rem SndPer (Just (n, m)) = "from the" <> descNthOfM n m
mkPorPrep Put ThrPer Nothing       = "in a"
mkPorPrep Put ThrPer (Just (n, m)) = "in the"   <> descNthOfM n m
mkPorPrep Rem ThrPer Nothing       = "from a"
mkPorPrep Rem ThrPer (Just (n, m)) = "from the" <> descNthOfM n m


descNthOfM :: Int -> Int -> T.Text
descNthOfM 1 1 = ""
descNthOfM n _ = " " <> mkOrdinal n


onTheGround :: Maybe NthOfM -> T.Text
onTheGround Nothing = ""
onTheGround _       = " on the ground"


-----


helperPutRemEitherInv :: Id                                  ->
                         PCDesig                             ->
                         PutOrRem                            ->
                         Maybe NthOfM                        ->
                         FromId                              ->
                         ToId                                ->
                         ToEnt                               ->
                         (WorldState, [Broadcast], [T.Text]) ->
                         Either T.Text Inv                   ->
                         (WorldState, [Broadcast], [T.Text])
helperPutRemEitherInv i d por mnom fi ti te a@(ws, bs, _) = \case
  Left  (mkBroadcast i -> b) -> over _2 (++ b) a
  Right is | (is', bs')      <- if ti `elem` is
                                  then (filter (/= ti) is, bs ++ [sorry])
                                  else (is, bs)
           , (fis, tis)      <- over both ((ws^.invTbl) !) (fi, ti)
           , ws'             <- ws & invTbl.at fi ?~ fis \\ is'
                                   & invTbl.at ti ?~ (sortInv ws . (tis ++) $ is')
           , (bs'', logMsgs) <- mkPutRemInvDesc i ws' d por mnom is' te
           -> set _1 ws' . set _2 (bs' ++ bs'') . over _3 (++ logMsgs) $ a
  where
    sorry = ("You can't put the " <> te^.sing <> " inside itself.", [i])


mkPutRemInvDesc :: Id -> WorldState -> PCDesig -> PutOrRem -> Maybe NthOfM -> Inv -> ToEnt -> ([Broadcast], [T.Text])
mkPutRemInvDesc i ws d por mnom is (view sing -> ts) | bs <- concatMap helper . mkNameCountBothList i ws $ is
                                                     = (bs, extractLogMsgs i bs)
  where
    helper (_, c, (s, _)) | c == 1 =
        [ (T.concat [ "You "
                    , mkPorVerb por SndPer
                    , mkArticle
                    , s
                    , " "
                    , mkPorPrep por SndPer mnom
                    , rest ], [i])
        , (T.concat [ serialize d
                    , " "
                    , mkPorVerb por ThrPer
                    , " a "
                    , s
                    , " "
                    , mkPorPrep por ThrPer mnom
                    , rest ], otherPCIds) ]
      where
        mkArticle | por == Put = " the "
                  | otherwise  = " a "
    helper (_, c, b) =
        [ (T.concat [ "You "
                    , mkPorVerb por SndPer
                    , " "
                    , showText c
                    , " "
                    , mkPlurFromBoth b
                    , " "
                    , mkPorPrep por SndPer mnom
                    , rest ], [i])
        , (T.concat [ serialize d
                    , " "
                    , mkPorVerb por ThrPer
                    , " "
                    , showText c
                    , " "
                    , mkPlurFromBoth b
                    , " "
                    , mkPorPrep por ThrPer mnom
                    , rest ], otherPCIds) ]
    rest       = T.concat [ " ", ts, onTheGround mnom, "."  ]
    otherPCIds = i `delete` pcIds d


-----


isRingRol :: RightOrLeft -> Bool
isRingRol = \case R -> False
                  L -> False
                  _ -> True


-----


mkCapStdDesig :: Id -> WorldState -> (PCDesig, Sing, PC, Id, Inv)
mkCapStdDesig i ws | (view sing -> s)    <- (ws^.entTbl) ! i
                   , p@(view rmId -> ri) <- (ws^.pcTbl)  ! i
                   , ris                 <- (ws^.invTbl) ! ri = (mkStdDesig i ws s True ris, s, p, ri, ris)


mkStdDesig :: Id -> WorldState -> Sing -> Bool -> Inv -> PCDesig
mkStdDesig i ws s ic ris = StdDesig { stdPCEntSing = Just s
                                    , isCap        = ic
                                    , pcEntName    = mkUnknownPCEntName i ws
                                    , pcId         = i
                                    , pcIds        = findPCIds ws ris }


-----


mkCoinsDesc :: Cols -> Coins -> T.Text
mkCoinsDesc cols (Coins (cop, sil, gol)) =
    T.unlines . intercalate [""] . map (wrap cols) . filter (not . T.null) $ [ copDesc, silDesc, golDesc ]
  where -- TODO: Come up with good descriptions.
    copDesc = if cop /= 0 then "The copper piece is round and shiny." else ""
    silDesc = if sil /= 0 then "The silver piece is round and shiny." else ""
    golDesc = if gol /= 0 then "The gold piece is round and shiny."   else ""


-----


mkDropReadyBindings :: Id -> WorldState -> (PCDesig, Id, Inv, Coins)
mkDropReadyBindings i ws | (d, _, _, ri, _) <- mkCapStdDesig i ws
                         , is               <- (ws^.invTbl)   ! i
                         , c                <- (ws^.coinsTbl) ! i = (d, ri, is, c)


-----


mkEntDescs :: Id -> Cols -> WorldState -> Inv -> T.Text
mkEntDescs i cols ws eis = T.intercalate "\n" . map (mkEntDesc i cols ws) $ [ (ei, (ws^.entTbl) ! ei) | ei <- eis ]


mkEntDesc :: Id -> Cols -> WorldState -> (Id, Ent) -> T.Text
mkEntDesc i cols ws (ei@(((ws^.typeTbl) !) -> t), e@(views entDesc (wrapUnlines cols) -> ed)) =
    case t of ConType ->                 (ed <>) . mkInvCoinsDesc i cols ws ei $ e
              MobType ->                 (ed <>) . mkEqDesc       i cols ws ei   e $ t
              PCType  -> (pcHeader <>) . (ed <>) . mkEqDesc       i cols ws ei   e $ t
              _       -> ed
  where
    pcHeader = wrapUnlines cols mkPCDescHeader
    mkPCDescHeader | (pp *** pp -> (s, r)) <- getSexRace ei ws = T.concat [ "You see a ", s, " ", r, "." ]


mkInvCoinsDesc :: Id -> Cols -> WorldState -> Id -> Ent -> T.Text
mkInvCoinsDesc i cols ws i' (view sing -> s) | is <- (ws^.invTbl)   ! i'
                                             , c  <- (ws^.coinsTbl) ! i' = case (not . null $ is, c /= mempty) of
  (False, False) -> wrapUnlines cols $ if i' == i then dudeYourHandsAreEmpty else "The " <> s <> " is empty."
  (True,  False) -> header <> mkEntsInInvDesc i cols ws is
  (False, True ) -> header <>                                 mkCoinsSummary cols c
  (True,  True ) -> header <> mkEntsInInvDesc i cols ws is <> mkCoinsSummary cols c
  where
    header | i' == i   = nl "You are carrying:"
           | otherwise = wrapUnlines cols $ "The " <> s <> " contains:"


dudeYourHandsAreEmpty :: T.Text
dudeYourHandsAreEmpty = "You aren't carrying anything."


mkEntsInInvDesc :: Id -> Cols -> WorldState -> Inv -> T.Text
mkEntsInInvDesc i cols ws = T.unlines . concatMap (wrapIndent ind cols . helper) . mkStyledNameCountBothList i ws
  where
    helper (pad ind -> en, c, (s, _)) | c == 1 = en <> "1 " <> s
    helper (pad ind -> en, c, b     )          = T.concat [ en, showText c, " ", mkPlurFromBoth b ]
    ind = 11


mkStyledNameCountBothList :: Id -> WorldState -> Inv -> [(T.Text, Int, BothGramNos)]
mkStyledNameCountBothList i ws is | ens   <- styleAbbrevs DoBracket [ getEffName        i ws i' | i' <- is ]
                                  , ebgns <-                        [ getEffBothGramNos i ws i' | i' <- is ]
                                  , cs    <- mkCountList ebgns = nub . zip3 ens cs $ ebgns


mkCoinsSummary :: Cols -> Coins -> T.Text
mkCoinsSummary cols c = helper [ mkNameAmt cn c' | cn <- coinNames | c' <- mkListFromCoins c ]
  where
    mkNameAmt cn a = if a == 0 then "" else showText a <> " " <> bracketQuote (abbrevColor <> cn <> dfltColor)
    helper         = T.unlines . wrapIndent 2 cols . T.intercalate ", " . filter (not . T.null)


mkEqDesc :: Id -> Cols -> WorldState -> Id -> Ent -> Type -> T.Text
mkEqDesc i cols ws i' (view sing -> s) t | descs <- if i' == i then mkDescsSelf else mkDescsOther =
    case descs of [] -> none
                  _  -> (header <>) . T.unlines . concatMap (wrapIndent 15 cols) $ descs
  where
    mkDescsSelf | (ss, is) <- unzip . M.toList $ (ws^.eqTbl) ! i
                , sns      <- [ pp s'                 | s' <- ss ]
                , es       <- [ (ws^.entTbl) ! ei     | ei <- is ]
                , ess      <- [ e^.sing               | e  <- es ]
                , ens      <- [ fromJust $ e^.entName | e  <- es ]
                , styleds  <- styleAbbrevs DoBracket ens = map helper . zip3 sns ess $ styleds
      where
        helper (T.breakOn " finger" -> (sn, _), es, styled) = T.concat [ parensPad 15 sn, es, " ", styled ]
    mkDescsOther | (ss, is) <- unzip . M.toList $ (ws^.eqTbl) ! i'
                 , sns      <- [ pp s' | s' <- ss ]
                 , ess      <- [ view sing $ (ws^.entTbl) ! ei | ei <- is ] = zipWith helper sns ess
      where
        helper (T.breakOn " finger" -> (sn, _)) es = parensPad 15 sn <> es
    none = wrapUnlines cols $ if
      | i' == i      -> dudeYou'reNaked
      | t  == PCType -> parsePCDesig i ws $ d <> " doesn't have anything readied."
      | otherwise    -> "The " <> s <> " doesn't have anything readied."
    header = wrapUnlines cols $ if
      | i' == i      -> "You have readied the following equipment:"
      | t  == PCType -> parsePCDesig i ws $ d <> " has readied the following equipment:"
      | otherwise    -> "The " <> s <> " has readied the following equipment:"
    d = mkSerializedNonStdDesig i' ws s The


dudeYou'reNaked :: T.Text
dudeYou'reNaked = "You don't have anything readied. You're naked!"


mkSerializedNonStdDesig :: Id -> WorldState -> Sing -> AOrThe -> T.Text
mkSerializedNonStdDesig i ws s (capitalize . pp -> aot) | (pp *** pp -> (s', r)) <- getSexRace i ws =
    serialize NonStdDesig { nonStdPCEntSing = s
                          , nonStdDesc      = T.concat [ aot, " ", s', " ", r ] }


-----


mkExitsSummary :: Cols -> Rm -> T.Text
mkExitsSummary cols (view rmLinks -> rls)
  | stdNames    <- [ exitsColor <> rl^.linkDir.to linkDirToCmdName <> dfltColor | rl <- rls
                                                                                , not . isNonStdLink $ rl ]
  , customNames <- [ exitsColor <> rl^.linkName                    <> dfltColor | rl <- rls
                                                                                ,       isNonStdLink   rl ]
  = T.unlines . wrapIndent 2 cols . ("Obvious exits: " <>) . summarize stdNames $ customNames
  where
    summarize []  []  = "None!"
    summarize std cus = T.intercalate ", " . (std ++) $ cus


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
isNonStdLink (NonStdLink {}) = True
isNonStdLink _               = False


-----


mkGetLookBindings :: Id -> WorldState -> (PCDesig, Id, Inv, Inv, Coins)
mkGetLookBindings i ws | (d, _, _, ri, ris@((i `delete`) -> ris')) <- mkCapStdDesig i ws
                       , rc                                        <- (ws^.coinsTbl) ! ri = (d, ri, ris, ris', rc)


-----


type IsConInRm  = Bool
type InvWithCon = Inv


mkMaybeNthOfM :: IsConInRm -> WorldState -> Id -> Ent -> InvWithCon -> Maybe NthOfM
mkMaybeNthOfM False _  _ _                _  = Nothing
mkMaybeNthOfM True  ws i (view sing -> s) is = Just . (succ . fromJust . elemIndex i *** length) . dup $ matches
  where
    matches = filter (\i' -> views sing (== s) $ (ws^.entTbl) ! i') is


-----


mkPutRemBindings :: Id -> WorldState -> Args -> (PCDesig, Inv, Coins, Inv, Coins, ConName, Args)
mkPutRemBindings i ws as = let (d, _, _, ri, (i `delete`) -> ris) = mkCapStdDesig i ws
                               pis                                = (ws^.invTbl) ! i
                               (pc, rc)                           = over both ((ws^.coinsTbl) !) (i, ri)
                               cn                                 = last as
                               (init -> argsWithoutCon)           = case as of [_, _] -> as
                                                                               _      -> (++ [cn]) . nub . init $ as
                           in (d, ris, rc, pis, pc, cn, argsWithoutCon)


-----


moveReadiedItem :: Id                                  ->
                   (WorldState, [Broadcast], [T.Text]) ->
                   EqMap                               ->
                   Slot                                ->
                   Id                                  ->
                   (T.Text, Broadcast)                 ->
                   (WorldState, [Broadcast], [T.Text])
moveReadiedItem i a@(ws, _, _) em s ei (msg, b)
  | is  <- (ws^.invTbl) ! i
  , ws' <- ws & invTbl.at i ?~ filter (/= ei) is
              & eqTbl.at  i ?~ (em & at s ?~ ei)
  , bs  <- mkBroadcast i msg ++ [b]
  = set _1 ws' . over _2 (++ bs) . over _3 (++ [msg]) $ a


-----


otherHand :: Hand -> Hand
otherHand RHand  = LHand
otherHand LHand  = RHand
otherHand NoHand = NoHand


-----


resolvePCInvCoins :: Id -> WorldState -> Args -> Inv -> Coins -> ([Either T.Text Inv], [Either [T.Text] Coins])
resolvePCInvCoins i ws as is c | (gecrs, miss, rcs) <- resolveEntCoinNames i ws as is c
                               , eiss               <- [ curry procGecrMisPCInv gecr mis | gecr <- gecrs | mis <- miss ]
                               , ecs                <- map procReconciledCoinsPCInv rcs = (eiss, ecs)


-----


resolveRmInvCoins :: Id -> WorldState -> Args -> Inv -> Coins -> ([Either T.Text Inv], [Either [T.Text] Coins])
resolveRmInvCoins i ws as is c | (gecrs, miss, rcs) <- resolveEntCoinNames i ws as is c
                               , eiss               <- [ curry procGecrMisRm gecr mis | gecr <- gecrs | mis <- miss ]
                               , ecs                <- map procReconciledCoinsRm rcs = (eiss, ecs)