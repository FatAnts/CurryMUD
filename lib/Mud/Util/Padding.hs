{-# OPTIONS_GHC -funbox-strict-fields -Wall -Werror #-}
{-# LANGUAGE OverloadedStrings, ViewPatterns #-}

module Mud.Util.Padding where

import Mud.Util.Quoting

import Control.Lens (folded, to)
import Control.Lens.Operators ((^..))
import Data.Monoid ((<>))
import qualified Data.Text as T


quoteWithAndPad :: (T.Text, T.Text) -> Int -> T.Text -> T.Text
quoteWithAndPad q x t = quoteWith' q t' <> T.replicate (x - T.length t' - 2) " "
  where
    t' = T.take (pred $ x - l) t
    l  = sum $ [ fst q, snd q ]^..folded.to T.length


bracketPad :: Int -> T.Text -> T.Text
bracketPad = quoteWithAndPad ("[", "]")


parensPad :: Int -> T.Text -> T.Text
parensPad = quoteWithAndPad ("(", ")")


padOrTrunc :: Int -> T.Text -> T.Text
padOrTrunc x _                 | x < 0 = ""
padOrTrunc x t@(T.length -> l) | l < x = t <> T.replicate (x - l) " "
                               | l > x = T.take x t
padOrTrunc _ t = t