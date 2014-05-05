{-# OPTIONS_GHC -Wall #-}
module SourceSyntax.Literal where

import Data.Map (Map)
import SourceSyntax.PrettyPrint
import qualified Text.PrettyPrint as PP

data Literal = IntNum Int
             | FloatNum Double
             | Chr Char
             | Str String
             | Boolean Bool
             deriving (Eq, Ord, Show)

instance Pretty Literal where
  pretty literal =
    case literal of
      IntNum n -> PP.int n
      FloatNum n -> PP.double n
      Chr c -> PP.text . show $ c
      Str s -> PP.text . show $ s
      Boolean bool -> PP.text (show bool)

data GLTipe = Int | Float | V2 | V3 | V4 | M4 | Texture
  deriving (Show)

glTipeName :: GLTipe -> String
glTipeName glTipe =
    case glTipe of
      Int     -> "Int"
      Float   -> "Float"
      V2      -> "Math.Vector.Vec2"
      V3      -> "Math.Vector.Vec3"
      V4      -> "Math.Vector.Vec4"
      M4      -> "Math.Matrix.Mat4"
      Texture -> "Graphics.WebGL.Texture"

data GLShaderTipe = GLShaderTipe
    { attribute :: Map String GLTipe
    , uniform :: Map String GLTipe
    , varying :: Map String GLTipe
    } deriving (Show)

