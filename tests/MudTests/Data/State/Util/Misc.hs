{-# LANGUAGE OverloadedStrings #-}

module MudTests.Data.State.Util.Misc where

import Mud.Data.State.MudData
import Mud.Data.State.Util.Misc
import Mud.TheWorld.Zones.AdminZone
import Mud.TopLvlDefs.Chars
import MudTests.TestUtil

import Control.Lens (to)
import Control.Lens.Operators ((^.))
import Data.Monoid ((<>))
import Data.Text (Text)
import qualified Data.IntMap.Lazy as IM (keys)
import qualified Data.Text as T
import Test.QuickCheck.Monadic (assert, monadicIO)
import Test.Tasty.HUnit ((@?=), Assertion)
import Test.Tasty.QuickCheck (Property)


prop_getUnusedId :: Property
prop_getUnusedId = monadicIO $ inWorld getState >>= \ms ->
    assert $ getUnusedId ms `notElem` ms^.typeTbl.to IM.keys


-- ==================================================


test_dropPrefixesForHooks_no_prefixes :: Assertion
test_dropPrefixesForHooks_no_prefixes = actual @?= expected
  where
    args     = [ "abc", "def", "ghi" ]
    actual   = dropPrefixesForHooks [ getFlowerHook, lookFlowerbedHook ] args
    expected = args


test_dropPrefixesForHooks_no_matches :: Assertion
test_dropPrefixesForHooks_no_matches = actual @?= expected
  where
    args     = [ attachPrefix ""   allChar    "abc"
               , attachPrefix "5"  amountChar "def"
               , attachPrefix "10" indexChar  "ghi" ]
    actual   = dropPrefixesForHooks [ getFlowerHook, lookFlowerbedHook ] args
    expected = args


attachPrefix :: Text -> Char -> Text -> Text
attachPrefix digits c t = digits <> (c `T.cons` t)


test_dropPrefixesForHooks_with_matches :: Assertion
test_dropPrefixesForHooks_with_matches = actual @?= expected
  where
    args     = [ attachPrefix ""   allChar    "abc"
               , attachPrefix ""   allChar    "flower"
               , attachPrefix "5"  amountChar "def"
               , attachPrefix "5"  amountChar "flowers"
               , attachPrefix "10" indexChar  "ghi"
               , attachPrefix "10" indexChar  "flowerbed" ]
    actual   = dropPrefixesForHooks [ getFlowerHook, lookFlowerbedHook ] args
    expected = [ attachPrefix ""   allChar    "abc"
               , "flower"
               , attachPrefix "5"  amountChar "def"
               , "flowers"
               , attachPrefix "10" indexChar  "ghi"
               , "flowerbed" ]


test_dropPrefixesForHooks_abbrev :: Assertion
test_dropPrefixesForHooks_abbrev = actual @?= expected
  where
    args     = [ attachPrefix "" allChar "flowe"
               , attachPrefix "" allChar "flower" ]
    actual   = dropPrefixesForHooks [ getFlowerHook, lookFlowerbedHook ] args
    expected = [ attachPrefix "" allChar "flowe"
               , "flower" ]
