{-# OPTIONS_GHC -funbox-strict-fields -Wall -Werror #-}
{-# LANGUAGE OverloadedStrings #-}

module Mud.TheWorld ( allKeys
                    , createWorld
                    , findAvailKey
                    , getUnusedId
                    , initWorld
                    , sortAllInvs ) where

import Mud.Ids
import Mud.StateDataTypes
import Mud.StateHelpers
import qualified Mud.Logging as L (logNotice)

import Control.Lens.Operators ((^.))
import Data.Functor ((<$>))
import Data.List ((\\))
import Data.Monoid (mempty)
import qualified Data.Map.Lazy as M (empty, fromList)

{-# ANN module ("HLint: ignore Reduce duplication" :: String) #-}


-- ==================================================
-- Misc. helper functions:


logNotice :: String -> String -> MudStack ()
logNotice = L.logNotice "Mud.TheWorld"


getUnusedId :: MudStack Id
getUnusedId = findAvailKey <$> allKeys


findAvailKey :: Inv -> Id
findAvailKey = head . (\\) [0..]


allKeys :: MudStack Inv
allKeys = keysWS typeTbl


-- ==================================================
-- Helper functions for registering world elements:


putObj :: Id -> Ent -> Obj -> MudStack ()
putObj i e o = onWorldState $ \ws -> do
    insert_STM i ObjType (ws^.typeTbl)
    insert_STM i e       (ws^.entTbl)
    insert_STM i o       (ws^.objTbl)


putCloth :: Id -> Ent -> Obj -> Cloth -> MudStack ()
putCloth i e o c = onWorldState $ \ws -> do
    insert_STM i ClothType (ws^.typeTbl)
    insert_STM i e         (ws^.entTbl)
    insert_STM i o         (ws^.objTbl)
    insert_STM i c         (ws^.clothTbl)


putCon :: Id -> Ent -> Obj -> Inv -> Coins -> Con -> MudStack ()
putCon i e o is coi con = onWorldState $ \ws -> do
    insert_STM i ConType (ws^.typeTbl)
    insert_STM i e       (ws^.entTbl)
    insert_STM i o       (ws^.objTbl)
    insert_STM i is      (ws^.invTbl)
    insert_STM i coi     (ws^.coinsTbl)
    insert_STM i con     (ws^.conTbl)


putWpn :: Id -> Ent -> Obj -> Wpn -> MudStack ()
putWpn i e o w = onWorldState $ \ws -> do
    insert_STM i WpnType (ws^.typeTbl)
    insert_STM i e       (ws^.entTbl)
    insert_STM i o       (ws^.objTbl)
    insert_STM i w       (ws^.wpnTbl)


putArm :: Id -> Ent -> Obj -> Arm -> MudStack ()
putArm i e o a = onWorldState $ \ws -> do
    insert_STM i ArmType (ws^.typeTbl)
    insert_STM i e       (ws^.entTbl)
    insert_STM i o       (ws^.objTbl)
    insert_STM i a       (ws^.armTbl)


putMob :: Id -> Ent -> Inv -> Coins -> EqMap -> Mob -> MudStack ()
putMob i e is c em m = onWorldState $ \ws -> do
    insert_STM i MobType (ws^.typeTbl)
    insert_STM i e       (ws^.entTbl)
    insert_STM i is      (ws^.invTbl)
    insert_STM i c       (ws^.coinsTbl)
    insert_STM i em      (ws^.eqTbl)
    insert_STM i m       (ws^.mobTbl)

putPC :: Id -> Ent -> Inv -> Coins -> EqMap -> Mob -> PC -> MudStack ()
putPC i e is c em m p = onWorldState $ \ws -> do
    insert_STM i PCType (ws^.typeTbl)
    insert_STM i e      (ws^.entTbl)
    insert_STM i is     (ws^.invTbl)
    insert_STM i c      (ws^.coinsTbl)
    insert_STM i em     (ws^.eqTbl)
    insert_STM i m      (ws^.mobTbl)
    insert_STM i p      (ws^.pcTbl)


putRm :: Id -> Inv -> Coins -> Rm -> MudStack ()
putRm i is c r = onWorldState $ \ws -> do
    insert_STM i RmType (ws^.typeTbl)
    insert_STM i is     (ws^.invTbl)
    insert_STM i c      (ws^.coinsTbl)
    insert_STM i r      (ws^.rmTbl)


putPla :: Id -> Pla -> MudStack ()
putPla i p = onNonWorldState $ \nws ->
    insert_STM i p (nws^.plaTbl)


-- ==================================================
-- Initializing and creating the world:


createWorld :: MudStack ()
createWorld = do
    logNotice "createWorld" "creating the world"

    putPla 0 (Pla 80)

    putPC 0 (Ent 0 "" "" "" "" 0) [iKewpie1, iBag1, iClub] (Coins (10, 0, 20)) (M.fromList [(RHandS, iSword1), (LHandS, iSword2)]) (Mob Male 10 10 10 10 10 10 0 LHand) (PC iHill Human)

    putRm iHill [iGP1, iLongSword] (Coins (0, 0, 1)) (Rm "The hill" "You stand atop a tall hill." 0 [RmLink "e" iCliff])
    putRm iCliff [iElephant, iBag2, iBracelet1, iBracelet2, iBracelet3, iBracelet4] mempty (Rm "The cliff" "You have reached the edge of a cliff. \
        \There is a sizeable hole in the ground. Next to the hole is a small hut." 0 [RmLink "w" iHill, RmLink "d" iHole, RmLink "hut" iHut])
    putRm iHole [iNeck1, iNeck2, iNeck3, iNeck4, iHelm] (Coins (50, 0, 0)) (Rm "The hole" "You have climbed into a hole in the ground. There is barely enough room to move around. \
        \It's damp and smells of soil." 0 [RmLink "w" iVoid, RmLink "u" iCliff])
    putRm iVoid [iEar1, iEar2, iEar3, iEar4, iRockCavy, iNoseRing1, iNoseRing2, iNoseRing3] mempty (Rm "The void" "You have stumbled into an empty space. The world dissolves into nothingness. You are floating." 0 [RmLink "e" iHole])
    putRm iHut [iLongName1, iLongName2] (Coins (0, 5, 0)) (Rm "The hut" "The tiny hut is dusty and smells of mold." 0 [RmLink "out" iCliff])

    putObj iKewpie1 (Ent iKewpie1 "doll" "kewpie doll" "" "The red kewpie doll is disgustingly cute." 0) (Obj 1 1)
    putObj iKewpie2 (Ent iKewpie2 "doll" "kewpie doll" "" "The orange kewpie doll is disgustingly cute." 0) (Obj 1 1)

    putObj iGP1 (Ent iGP1 "guinea" "guinea pig" "" "The yellow guinea pig is charmingly cute." 0) (Obj 1 1)
    putObj iGP2 (Ent iGP2 "guinea" "guinea pig" "" "The green guinea pig is charmingly cute." 0) (Obj 1 1)
    putObj iGP3 (Ent iGP3 "guinea" "guinea pig" "" "The blue guinea pig is charmingly cute." 0) (Obj 1 1)

    putObj iElephant (Ent iElephant "elephant" "elephant" "" "The elephant is huge and smells terrible." 0) (Obj 1 1)

    putCon iBag1 (Ent iBag1 "sack" "cloth sack" "" "It's a typical cloth sack, perfect for holding all your treasure. It's red." 0) (Obj 1 1) [iGP2, iGP3] (Coins (15, 10, 5)) (Con 10)
    putCon iBag2 (Ent iBag2 "sack" "cloth sack" "" "It's a typical cloth sack, perfect for holding all your treasure. It's blue." 0) (Obj 1 1) [iKewpie2, iRing1, iRing2, iRing3, iRing4] (Coins (15, 10, 5)) (Con 10)

    putWpn iSword1 (Ent iSword1 "sword" "short sword" "" "It's a sword; short but still sharp! It's silver." 0) (Obj 1 1) (Wpn OneHanded 1 10)
    putWpn iSword2 (Ent iSword2 "sword" "short sword" "" "It's a sword; short but still sharp! It's gold." 0) (Obj 1 1) (Wpn OneHanded 1 10)

    putWpn iClub (Ent iClub "club" "wooden club" "" "It's a crude wooden club; the type a neanderthal might use to great effect." 0) (Obj 1 1) (Wpn OneHanded 1 5)

    putWpn iLongSword (Ent iLongSword "sword" "two-handed long sword" "" "What a big sword! With the right technique it could do a great deal of damage." 0) (Obj 1 1) (Wpn TwoHanded 5 20)

    putCloth iBracelet1 (Ent iBracelet1 "bracelet" "bronze bracelet" "" "It's a simple bronze bracelet." 0) (Obj 1 1) WristC
    putCloth iBracelet2 (Ent iBracelet2 "bracelet" "silver bracelet" "" "It's a simple silver bracelet." 0) (Obj 1 1) WristC
    putCloth iBracelet3 (Ent iBracelet3 "bracelet" "gold bracelet" "" "It's a simple gold bracelet." 0) (Obj 1 1) WristC
    putCloth iBracelet4 (Ent iBracelet4 "bracelet" "platinum bracelet" "" "It's a simple platinum bracelet." 0) (Obj 1 1) WristC

    putCloth iRing1 (Ent iRing1 "ring" "bronze ring" "" "It's a simple bronze ring." 0) (Obj 1 1) FingerC
    putCloth iRing2 (Ent iRing2 "ring" "silver ring" "" "It's a simple silver ring." 0) (Obj 1 1) FingerC
    putCloth iRing3 (Ent iRing3 "ring" "gold ring" "" "It's a simple gold ring." 0) (Obj 1 1) FingerC
    putCloth iRing4 (Ent iRing4 "ring" "platinum ring" "" "It's a simple platinum ring." 0) (Obj 1 1) FingerC

    putCloth iNeck1 (Ent iNeck1 "necklace" "bronze necklace" "" "It's a simple bronze necklace." 0) (Obj 1 1) NeckC
    putCloth iNeck2 (Ent iNeck2 "necklace" "silver necklace" "" "It's a simple silver necklace." 0) (Obj 1 1) NeckC
    putCloth iNeck3 (Ent iNeck3 "necklace" "gold necklace" "" "It's a simple gold necklace." 0) (Obj 1 1) NeckC
    putCloth iNeck4 (Ent iNeck4 "necklace" "platinum necklace" "" "It's a simple platinum necklace." 0) (Obj 1 1) NeckC

    putCloth iEar1 (Ent iEar1 "earring" "azure earring" "" "It's a small, but tasteful, nondescript hoop." 0) (Obj 1 1) EarC
    putCloth iEar2 (Ent iEar2 "earring" "coral earring" "" "It's a small, but tasteful, nondescript hoop." 0) (Obj 1 1) EarC
    putCloth iEar3 (Ent iEar3 "earring" "sea green earring" "" "It's a small, but tasteful, nondescript hoop." 0) (Obj 1 1) EarC
    putCloth iEar4 (Ent iEar4 "earring" "mithril earring" "" "It's a small, but tasteful, nondescript hoop." 0) (Obj 1 1) EarC

    putArm iHelm (Ent iHelm "helmet" "leather helmet" "" "Nothing to write home about. But it's better than nothing." 0) (Obj 1 1) (Arm HeadA 1)

    putMob iRockCavy (Ent iRockCavy "rock" "rock cavy" "rock cavies" "It looks like a slightly oversized guinea pig. \
        \You imagine that the rock cavy would prefer dry, rocky areas (with low, scrubby vegetation), close to stony mountains and hills." 0) [] mempty M.empty (Mob Male 10 10 10 10 10 10 25 NoHand)

    putCloth iNoseRing1 (Ent iNoseRing1 "nose" "nose ring" "" "It's a plain silver stud, intended to be worn on the nose." 0) (Obj 1 1) NoseC
    putCloth iNoseRing2 (Ent iNoseRing2 "nose" "nose ring" "" "It's a plain silver stud, intended to be worn on the nose." 0) (Obj 1 1) NoseC
    putCloth iNoseRing3 (Ent iNoseRing3 "nose" "nose ring" "" "It's a plain silver stud, intended to be worn on the nose." 0) (Obj 1 1) NoseC

    putObj iLongName1 (Ent iLongName1 "long" "item with a very long name, gosh this truly is a long name, it just goes on and on, no one knows when it might stop" "" "It's long." 0) (Obj 1 1)
    putObj iLongName2 (Ent iLongName2 "long" "item with a very long name, gosh this truly is a long name, it just goes on and on, no one knows when it might stop" "" "It's long." 0) (Obj 1 1)


initWorld :: MudStack ()
initWorld = createWorld >> sortAllInvs


sortAllInvs :: MudStack ()
sortAllInvs = do
    logNotice "sortAllInvs" "sorting all inventories"
    mapM_ sortEach =<< keysWS invTbl
  where
    sortEach i = i `lookupWS` invTbl >>= sortInv >>= \is ->
        insertWS i is invTbl
