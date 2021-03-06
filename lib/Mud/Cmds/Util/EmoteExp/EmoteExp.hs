{-# LANGUAGE FlexibleContexts, MultiWayIf, OverloadedStrings, TupleSections, ViewPatterns #-}

module Mud.Cmds.Util.EmoteExp.EmoteExp ( adminChanEmotify
                                       , adminChanExpCmdify
                                       , adminChanTargetify
                                       , emotify
                                       , expCmdify
                                       , targetify ) where

import Mud.Cmds.ExpCmds
import Mud.Cmds.Msgs.Advice
import Mud.Cmds.Msgs.Sorry
import Mud.Cmds.Util.CmdPrefixes
import Mud.Cmds.Util.Misc
import Mud.Data.Misc
import Mud.Data.State.ActionParams.Misc
import Mud.Data.State.MudData
import Mud.Data.State.Util.Get
import Mud.Data.State.Util.Misc
import Mud.Data.State.Util.Output
import Mud.Misc.ANSI
import Mud.TopLvlDefs.Chars
import Mud.TopLvlDefs.Misc
import Mud.Util.List hiding (headTail)
import Mud.Util.Misc hiding (patternMatchFail)
import Mud.Util.Operators
import Mud.Util.Quoting
import Mud.Util.Text
import qualified Mud.Util.Misc as U (patternMatchFail)

import Control.Arrow ((&&&))
import Control.Lens (_1, _2, both, each, view, views)
import Control.Lens.Operators ((%~), (&), (<>~))
import Data.Char (isLetter)
import Data.Either (lefts)
import Data.List ((\\), delete, intersperse, nub)
import Data.Monoid ((<>))
import Data.Text (Text)
import Data.Tuple (swap)
import qualified Data.Text as T


patternMatchFail :: (Show a) => PatternMatchFail a b
patternMatchFail = U.patternMatchFail "Mud.Cmds.Util.EmoteExp.EmoteExp"


-- ==================================================


targetify :: Id -> ChanContext -> [(Id, Text, Text)] -> Text -> Either Text (Either () [Broadcast])
targetify i cc triples msg@(T.words -> ws@(headTail . head -> (c, rest)))
  | isBracketed ws               = Left sorryBracketedMsg
  | isHeDon't chanTargetChar msg = Left sorryWtf
  | c == chanTargetChar          = fmap Right . procChanTarget i cc triples . parseOutDenotative ws $ rest
  | otherwise = Right . Left $ ()


procChanTarget :: Id -> ChanContext -> [(Id, Text, Text)] -> Args -> Either Text [Broadcast]
procChanTarget i cc triples ((T.toLower -> target):rest)
  | ()# rest  = Left sorryChanMsg
  | otherwise = case findFullNameForAbbrev target . map (views _2 T.toLower) $ triples of
    Nothing -> Left . sorryChanTargetNameFromContext target $ cc
    Just n  -> let targetId    = getIdForMatch n
                   tunedIds    = select _1 triples
                   msg         = capitalizeMsg . T.unwords $ rest
                   formatMsg x = parensQuote ("to " <> x) |<>| msg
               in Right [ (formatMsg . embedId $ targetId, pure i)
                        , (formatMsg . embedId &&& flip delete tunedIds) targetId
                        , (formatMsg . colorWith emoteTargetColor $ "you", pure targetId) ]
  where
    getIdForMatch match  = view _1 . head . filter (views _2 ((== match) . T.toLower)) $ triples
procChanTarget _ _ _ as = patternMatchFail "procChanTarget" . showText $ as


-----


emotify :: Id -> MudState -> ChanContext -> [(Id, Text, Text)] -> Text -> Either [Text] (Either () [Broadcast])
emotify i ms cc triples msg@(T.words -> ws@(headTail . head -> (c, rest)))
  | isHeDon't emoteChar msg = Left . pure $ sorryWtf
  | c == emoteChar          = fmap Right . procEmote i ms cc triples . parseOutDenotative ws $ rest
  | otherwise = Right . Left $ ()


procEmote :: Id -> MudState -> ChanContext -> [(Id, Text, Text)] -> Args -> Either [Text] [Broadcast]
procEmote _ _  cc _       as | hasYou as = Left . pure . adviceYouEmoteChar . pp $ cc
procEmote i ms cc triples as             =
    let me                      = (getSing i ms, embedId i, embedId i)
        xformed                 = xformArgs True as
        xformArgs _      []     = []
        xformArgs _      [x]
          | (h, t) <- headTail x
          , h == emoteNameChar
          , all isPunc . T.unpack $ t
          = pure . mkRightForNonTargets $ me & each <>~ t
        xformArgs isHead (x:xs) = (: xformArgs False xs) $ if
          | x == enc            -> mkRightForNonTargets me
          | x == enc's          -> mkRightForNonTargets (me & each <>~ "'s")
          | enc `T.isInfixOf` x -> Left . adviceEnc $ cc'
          | x == etc            -> Left . adviceEtc $ cc'
          | T.take 1 x == etc   -> isHead ? Left adviceEtcHead :? (procTarget . T.tail $ x)
          | etc `T.isInfixOf` x -> Left . adviceEtc $ cc'
          | isHead, hasEnc as   -> mkRightForNonTargets . dup3 . capitalizeMsg $ x
          | isHead              -> mkRightForNonTargets (me & each <>~ spcL x)
          | otherwise           -> mkRightForNonTargets . dup3 $ x
    in case lefts xformed of
      []      -> let (toSelf, toOthers, targetIds, toTargetBs) = happyTimes ms xformed
                 in Right $ (toSelf, pure i) : (toOthers, tunedIds \\ targetIds) : toTargetBs
      advices -> Left . intersperse "" . nub $ advices
  where
    cc'             = pp cc |<>| T.singleton emoteChar
    procTarget word =
        case swap . (both %~ T.reverse) . T.span isPunc . T.reverse $ word of
          ("",   _) -> Left . adviceEtc $ cc'
          ("'s", _) -> Left adviceEtcBlankPoss
          (w,    p) ->
            let (isPoss, target) = ("'s" `T.isSuffixOf` w ? (True, T.dropEnd 2) :? (False, id)) & _2 %~ (w |&|)
                notFound         = Left . sorryChanTargetNameFromContext target $ cc
                found match      =
                    let targetId = view _1 . head . filter (views _2 ((== match) . T.toLower)) $ triples
                        txt      = addSuffix isPoss p . embedId $ targetId
                    in Right ( txt
                             , [ mkEmoteWord isPoss p targetId, ForNonTargets txt ]
                             , txt )
            in findFullNameForAbbrev (T.toLower target) (map (views _2 T.toLower) triples) |&| maybe notFound found
    addSuffix   isPoss p = (<> p) . onTrue isPoss (<> "'s")
    mkEmoteWord isPoss   = isPoss ? ForTargetPoss :? ForTarget
    tunedIds             = select _1 triples


-----


expCmdify :: Id -> MudState -> ChanContext -> [(Id, Text, Text)] -> Text -> Either Text ([Broadcast], Text)
expCmdify i ms cc triples msg@(T.words -> ws@(headTail . head -> (c, rest)))
  | isHeDon't expCmdChar msg = Left sorryWtf
  | c == expCmdChar          = fmap format . procExpCmd i ms cc triples . parseOutDenotative ws $ rest
  | otherwise                = Right . (pure . (, i : select _1 triples) &&& id) $ msg
  where
    format xs = xs & _1 %~ map (_1 %~ angleBracketQuote)
                   & _2 %~ angleBracketQuote


procExpCmd :: Id -> MudState -> ChanContext -> [(Id, Text, Text)] -> Args -> Either Text ([Broadcast], Text)
procExpCmd _ _  _  _       (_:_:_:_)                               = Left sorryExpCmdLen
procExpCmd i ms cc triples (map T.toLower . unmsg -> [cn, target]) =
    findFullNameForAbbrev cn expCmdNames |&| maybe notFound found
  where
    found match =
        let ExpCmd _ ct _ _ = getExpCmdByName match
            tunedIds        = select _1 triples
        in case ct of
          NoTarget toSelf toOthers -> if ()# target
            then Right . (((format Nothing toOthers, tunedIds) :) . mkBcast i &&& id) $ toSelf
            else Left . sorryExpCmdIllegalTarget $ match
          HasTarget toSelf toTarget toOthers -> if ()# target
            then Left . sorryExpCmdRequiresTarget $ match
            else case findTarget of
              Nothing -> Left . sorryChanTargetNameFromContext target $ cc
              Just n  -> let targetId = getIdForMatch n
                             f        = ((colorizeYous . format Nothing $ toTarget, pure targetId             ) :)
                             g        = ((format (Just targetId) toOthers,          targetId `delete` tunedIds) :)
                         in Right . (f . g . mkBcast i &&& id) . format (Just targetId) $ toSelf
          Versatile toSelf toOthers toSelfWithTarget toTarget toOthersWithTarget -> if ()# target
            then Right . (((format Nothing toOthers, tunedIds) :) . mkBcast i &&& id) $ toSelf
            else case findTarget of
              Nothing -> Left . sorryChanTargetNameFromContext target $ cc
              Just n  -> let targetId          = getIdForMatch n
                             f                 = ((colorizeYous . format Nothing $ toTarget,  pure targetId             ) :)
                             g                 = ((format (Just targetId) toOthersWithTarget, targetId `delete` tunedIds) :)
                         in Right . (f . g . mkBcast i &&& id) . format (Just targetId) $ toSelfWithTarget
    notFound             = Left . sorryExpCmdName $ cn
    findTarget           = findFullNameForAbbrev target . map (views _2 T.toLower) $ triples
    getIdForMatch match  = view _1 . head . filter (views _2 ((== match) . T.toLower)) $ triples
    format maybeTargetId =
        let substitutions = [ ("%", embedId i), ("^", heShe), ("&", hisHer), ("*", himHerself) ]
        in replace (substitutions ++ maybe [] (pure . ("@", ) . embedId) maybeTargetId)
    (heShe, hisHer, himHerself) = mkPros . getSex i $ ms
    colorizeYous                = T.unwords . map helper . T.words
      where
        helper w = let (a, b) = T.break isLetter w
                       (c, d) = T.span  isLetter b
                   in T.toLower c `elem` yous ? (a <> colorWith emoteTargetColor c <> d) :? w
procExpCmd _ _ _ _ as = patternMatchFail "procExpCmd" . showText $ as


-----


adminChanTargetify :: Inv -> [Sing] -> Text -> Either Text (Either () [Broadcast])
adminChanTargetify tunedIds tunedSings msg@(T.words -> ws@(headTail . head -> (c, rest)))
  | isBracketed ws               = Left sorryBracketedMsg
  | isHeDon't chanTargetChar msg = Left sorryWtf
  | c == chanTargetChar          =
      fmap Right . adminChanProcChanTarget tunedIds tunedSings . parseOutDenotative ws $ rest
  | otherwise = Right . Left $ ()


adminChanProcChanTarget :: Inv -> [Sing] -> Args -> Either Text [Broadcast]
adminChanProcChanTarget tunedIds tunedSings ((capitalize . T.toLower -> target):rest) =
    ()# rest ? Left sorryChanMsg :? (findFullNameForAbbrev target tunedSings |&| maybe notFound found)
  where
    notFound         = Left . sorryAdminChanTargetName $ target
    found targetSing =
        let targetId    = fst . head . filter ((== targetSing) . snd) . zip tunedIds $ tunedSings
            msg         = capitalizeMsg . T.unwords $ rest
            formatMsg x = parensQuote ("to " <> x) |<>| msg
        in Right [ (formatMsg targetSing,                           targetId `delete` tunedIds)
                 , (formatMsg . colorWith emoteTargetColor $ "you", pure targetId             ) ]
adminChanProcChanTarget _ _ as = patternMatchFail "adminChanProcChanTarget" . showText $ as


-----


adminChanEmotify :: Id -> MudState -> Inv -> [Sing] -> Text -> Either [Text] (Either () [Broadcast])
adminChanEmotify i ms tunedIds tunedSings msg@(T.words -> ws@(headTail . head -> (c, rest)))
  | isHeDon't emoteChar msg = Left . pure $ sorryWtf
  | c == emoteChar          =
      fmap Right . adminChanProcEmote i ms tunedIds tunedSings . parseOutDenotative ws $ rest
  | otherwise = Right . Left $ ()


adminChanProcEmote :: Id -> MudState -> Inv -> [Sing] -> Args -> Either [Text] [Broadcast]
adminChanProcEmote _ _  _        _          as | hasYou as = Left . pure . adviceYouEmoteChar . prefixAdminCmd $ "admin"
adminChanProcEmote i ms tunedIds tunedSings as =
    let s                       = getSing i ms
        xformed                 = xformArgs True as
        xformArgs _      []     = []
        xformArgs _      [x]
          | (h, t) <- headTail x
          , h == emoteNameChar
          , all isPunc . T.unpack $ t
          = pure . mkRightForNonTargets . dup3 $ s <> t
        xformArgs isHead (x:xs) = (: xformArgs False xs) $ if
          | x == enc            -> mkRightForNonTargets . dup3 $ s
          | x == enc's          -> mkRightForNonTargets . dup3 $ s <> "'s"
          | enc `T.isInfixOf` x -> Left . adviceEnc $ cn
          | x == etc            -> Left . adviceEtc $ cn
          | T.take 1 x == etc   -> isHead ? Left adviceEtcHead :? procTarget (T.tail x)
          | etc `T.isInfixOf` x -> Left . adviceEtc $ cn
          | isHead, hasEnc as   -> mkRightForNonTargets . dup3 . capitalizeMsg $ x
          | isHead              -> mkRightForNonTargets . dup3 $ s |<>| x
          | otherwise           -> mkRightForNonTargets . dup3 $ x
    in case lefts xformed of
      [] -> let (toSelf, toOthers, targetIds, toTargetBs) = happyTimes ms xformed
            in Right $ (toSelf, pure i) : (toOthers, tunedIds \\ (i : targetIds)) : toTargetBs
      advices -> Left . intersperse "" . nub $ advices
  where
    cn              = prefixAdminCmd "admin" |<>| T.singleton emoteChar
    procTarget word =
        case swap . (both %~ T.reverse) . T.span isPunc . T.reverse $ word of
          ("",   _) -> Left . adviceEtc $ cn
          ("'s", _) -> Left adviceEtcBlankPoss
          (w,    p) ->
            let (isPoss, target) = ("'s" `T.isSuffixOf` w ? (True, T.dropEnd 2) :? (False, id)) & _2 %~ (w |&|)
                target'          = capitalize . T.toLower $ target
                notFound         = Left . sorryAdminChanTargetName $ target
                found targetSing@(addSuffix isPoss p -> targetSing') =
                    let targetId = head . filter ((== targetSing) . (`getSing` ms)) $ tunedIds
                    in Right ( targetSing'
                             , [ mkEmoteWord isPoss p targetId, ForNonTargets targetSing' ]
                             , targetSing' )
            in findFullNameForAbbrev target' (getSing i ms `delete` tunedSings) |&| maybe notFound found
    addSuffix   isPoss p = (<> p) . onTrue isPoss (<> "'s")
    mkEmoteWord isPoss   = isPoss ? ForTargetPoss :? ForTarget


-----


adminChanExpCmdify :: Id -> MudState -> Inv -> [Sing] -> Text -> Either Text ([Broadcast], Text)
adminChanExpCmdify i ms tunedIds tunedSings msg@(T.words -> ws@(headTail . head -> (c, rest)))
  | isHeDon't expCmdChar msg = Left sorryWtf
  | c == expCmdChar          =
      fmap format . adminChanProcExpCmd i ms tunedIds tunedSings . parseOutDenotative ws $ rest
  | otherwise = Right . (pure . (, tunedIds) &&& id) $ msg
  where
    format xs = xs & _1 %~ map (_1 %~ angleBracketQuote)
                   & _2 %~ angleBracketQuote


adminChanProcExpCmd :: Id -> MudState -> Inv -> [Sing] -> Args -> Either Text ([Broadcast], Text)
adminChanProcExpCmd _ _ _ _ (_:_:_:_) = Left sorryExpCmdLen
adminChanProcExpCmd i ms tunedIds tunedSings (map T.toLower . unmsg -> [cn, target]) =
    findFullNameForAbbrev cn expCmdNames |&| maybe notFound found
  where
    found match =
        let ExpCmd _ ct _ _ = getExpCmdByName match
        in case ct of
          NoTarget toSelf toOthers -> if ()# target
            then Right . (((format Nothing toOthers, i `delete` tunedIds) :) . mkBcast i &&& id) $ toSelf
            else Left . sorryExpCmdIllegalTarget $ match
          HasTarget toSelf toTarget toOthers -> if ()# target
            then Left . sorryExpCmdRequiresTarget $ match
            else case findTarget of
              Nothing -> Left . sorryAdminChanTargetName $ target
              Just n  -> let targetId = getIdForMobSing n ms
                             toSelf'  = format (Just n) toSelf
                             f        = ((colorizeYous . format Nothing $ toTarget, pure targetId              ) :)
                             g        = ((format (Just n) toOthers,                 tunedIds \\ [ i, targetId ]) :)
                         in Right . (f . g . mkBcast i &&& id) $ toSelf'
          Versatile toSelf toOthers toSelfWithTarget toTarget toOthersWithTarget -> if ()# target
            then Right . (((format Nothing toOthers, i `delete` tunedIds) :) . mkBcast i &&& id) $ toSelf
            else case findTarget of
              Nothing -> Left . sorryAdminChanTargetName $ target
              Just n  -> let targetId          = getIdForMobSing n ms
                             toSelfWithTarget' = format (Just n) toSelfWithTarget
                             f                 = ((colorizeYous . format Nothing $ toTarget, pure targetId              ) :)
                             g                 = ((format (Just n) toOthersWithTarget,       tunedIds \\ [ i, targetId ]) :)
                         in Right . (f . g . mkBcast i &&& id) $ toSelfWithTarget'
    notFound   = Left . sorryExpCmdName $ cn
    findTarget = findFullNameForAbbrev (capitalize target) $ getSing i ms `delete` tunedSings
    format maybeTargetSing =
        let substitutions = [ ("%", s), ("^", heShe), ("&", hisHer), ("*", himHerself) ]
        in replace (substitutions ++ maybe [] (pure . ("@", )) maybeTargetSing)
    s                           = getSing i ms
    (heShe, hisHer, himHerself) = mkPros . getSex i $ ms
    colorizeYous                = T.unwords . map helper . T.words
      where
        helper w = let (a, b) = T.break isLetter w
                       (c, d) = T.span  isLetter b
                   in T.toLower c `elem` yous ? (a <> colorWith emoteTargetColor c <> d) :? w
adminChanProcExpCmd _ _ _ _ as = patternMatchFail "adminChanProcExpCmd" . showText $ as
