{-# LANGUAGE OverloadedStrings, TransformListComp, ViewPatterns #-}

-- This module contains state-related functions used by multiple modules.

module Mud.Data.State.Util.Misc ( BothGramNos
                                , findPCIds
                                , getEffBothGramNos
                                , getEffName
                                , getSexRace
                                , mkPlaIdsSingsList
                                , mkPlurFromBoth
                                , mkSerializedNonStdDesig
                                , mkUnknownPCEntName
                                , modifyState
                                , sortInv ) where

import Mud.Data.Misc
import Mud.Data.State.MudData
import Mud.Util.Misc
import Mud.Util.Text

import Control.Arrow ((***))
import Control.Lens (_1, _2, both, over)
import Control.Lens.Getter (view, views)
import Control.Lens.Operators ((^.))
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (ask)
import Data.IORef (atomicModifyIORef)
import Data.IntMap.Lazy ((!))
import Data.List (sortBy)
import Data.Maybe (fromJust, fromMaybe)
import Data.Monoid ((<>))
import GHC.Exts (sortWith)
import qualified Data.IntMap.Lazy as IM (keys)
import qualified Data.Text as T


findPCIds :: MudState -> [Id] -> [Id]
findPCIds (view typeTble -> tt) haystack = [ i | i <- haystack, tt ! i == PCType ]


getEffBothGramNos :: Id -> MudState -> Id -> BothGramNos
getEffBothGramNos i ms targetId =
    let targetEnt = views entTbl (! targetId) ms
    in case targetEnt^.entName of
      Nothing | intros                                  <- views pcTbl (view introduced . (! i)) ms
              , targetSing                              <- targetEnt^.sing
              , (pp *** pp -> (targetSexy, targetRace)) <- getSexRace targetId
              -> if targetSing `elem` intros
                then (targetSing, "")
                else over both ((targetSexy <>) . (" " <>)) (targetRace, pluralize targetRace)
      Just _  -> (targetEnt^.sing, targetEnt^.plur)
  where
    pluralize "dwarf" = "dwarves"
    pluralize "elf"   = "elves"
    pluralize r       = r <> "s"


getEffName :: Id -> MudState -> Id -> T.Text
getEffName i ms targetId = let targetEnt  = views entTbl (! targetId) ms
                               targetSing = targetEnt^.sing
                           in fromMaybe helper $ targetEnt^.entName
  where
    helper | views introduced (targetSing `elem`) (views pcTbl (! i) ms) = uncapitalize targetSing
           | otherwise                                                   = mkUnknownPCEntName targetId ms


getSexRace :: Id -> MudState -> (Sex, Race)
getSexRace i ms = (views mobTbl (view sex . (! i)) ms, views pcTbl (view race . (! i)) ms)


mkPlaIdsSingsList :: MudState -> [(Id, Sing)]
mkPlaIdsSingsList ms@(view plaTbl -> pt) = [ (i, s) | i <- IM.keys pt
                                           , not . getPlaFlag IsAdmin $ pt ! i
                                           , let s = views entTbl (view sing . (! i)) ms
                                           , then sortWith by s ]


type BothGramNos = (Sing, Plur)


mkPlurFromBoth :: BothGramNos -> Plur
mkPlurFromBoth (s, "") = s <> "s"
mkPlurFromBoth (_, p ) = p


mkSerializedNonStdDesig :: Id -> MudState -> Sing -> AOrThe -> T.Text
mkSerializedNonStdDesig i ms s (capitalize . pp -> aot) = let (pp *** pp -> (sexy, r)) = getSexRace i ms in
    serialize NonStdDesig { nonStdPCEntSing = s, nonStdDesc = T.concat [ aot, " ", sexy, " ", r ] }


mkUnknownPCEntName :: Id -> MudState -> T.Text
mkUnknownPCEntName i ms | s <- views mobTbl (view sex  . (! i)) ms
                        , r <- views pcTbl  (view race . (! i)) ms = (T.singleton . T.head . pp $ s) <> pp r


modifyState :: (MudState -> (MudState, a)) -> MudStack a
modifyState f = ask >>= \md -> liftIO .  atomicModifyIORef (md^.mudStateIORef) $ f


sortInv :: MudState -> Inv -> Inv
sortInv ms is | (foldr helper ([], []) -> (pcIs, nonPCIs)) <- [ (i, views typeTbl (! i) ms) | i <- is ]
              = (pcIs ++) . sortNonPCs $ nonPCIs
  where
    helper (i, t) acc                  = let consTo lens = over lens (i :) acc
                                         in t == PCType ? consTo _1 :? consTo _2
    sortNonPCs                         = map (view _1) . sortBy nameThenSing . zipped
    nameThenSing (_, n, s) (_, n', s') = (n `compare` n') <> (s `compare` s')
    zipped nonPCIs                     = [ (i, views entName fromJust e, e^.sing) | i <- nonPCIs
                                                                                  , let e = views entTbl (! i) ms ]
