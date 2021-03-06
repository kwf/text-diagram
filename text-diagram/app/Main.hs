
module Main where

import Data.Ix
import Data.Traversable
import Data.Foldable
import Data.Maybe
import Control.Monad
import Control.Monad.Reader
import Data.Array.IO
import Data.IORef
import Data.Coerce
import Data.List.NonEmpty (NonEmpty(..), nonEmpty)
import qualified Data.List.NonEmpty as NE

import Text.Graphics.BoxDrawing

main :: IO ()
main =
  runGame (7,7) $ do
    unsafePlay A (7,7)
    unsafePlay B (6,7)
    unsafePlay A (5,7)
    unsafePlay B (6,6)
    rotate clockwise
    liftIO . print =<< available
    drawing <- drawPick A (3,5)
    liftIO $ sketchOut character (35,15) drawing
  where
    origin = (1,1)

    drawPick player position =
      mconcatA
        [ drawBorders origin
        , return (placing origin player position)
        , drawPieces origin
        ]

mconcatA :: (Applicative f, Monoid m, Foldable t) => t (f m) -> f m
mconcatA = fmap mconcat . sequenceA . toList

-- Players

data Piece
  = A
  | B
  deriving (Eq, Ord)

instance Show Piece where
  show = \case
    A -> "○"
    B -> "◼"

-- renderPiece :: Piece -> String
-- renderPiece = \case
--   A ->
--     "╭─╮" ++ "\n" ++
--     "╰─╯"
--   B ->
--     "┼─┼" ++ "\n" ++
--     "┼─┼"

-- Board positions and how to translate them for print

newtype CoordX
  = CoordX X
  deriving (Eq, Ord, Num, Enum, Integral, Real, Ix)
  deriving newtype (Show)

newtype CoordY
  = CoordY Y
  deriving (Eq, Ord, Num, Enum, Integral, Real, Ix)
  deriving newtype (Show)

type Position = (CoordX, CoordY)

type Origin = Point

-- The board

data Board where
  Board :: !(IORef Direction)
        -> !(IOArray Position (Maybe Piece))
        -> Board

newtype Game a
  = Game (ReaderT Board IO a)
  deriving (Functor, Applicative, Monad, MonadIO)

game :: (Board -> IO a) -> Game a
game = coerce

runGame :: Position -> Game a -> IO a
runGame size (Game g) = do
  board <- newBoard size
  runReaderT g board

newBoard :: Position -> IO Board
newBoard size = do
  orientation <- newIORef (Dir U)
  locations   <- newArray ((1,1), size) Nothing
  return (Board orientation locations)

rotate :: (forall d. Cardinal d -> Cardinal (Rotate d)) -> Game ()
rotate twist =
  game $ \(Board orientation _) ->
    modifyIORef' orientation (\(Dir d) -> Dir (twist d))

throughRotation :: Cardinal d -> Position -> Position -> Position
throughRotation up (x_max, y_max) (x, y) =
  case up of
    U -> (x, y)
    L -> (fromIntegral (y_max - y + 1), fromIntegral x)
    R -> (fromIntegral y, fromIntegral (x_max - x + 1))
    D -> (x_max - x + 1, y_max - y + 1)

boardParams :: Board -> IO (Direction, Position)
boardParams (Board orientation locations) = do
  dir <- readIORef orientation
  bounds <- snd <$> getBounds locations
  return (dir, bounds)

physicalPosition :: Board -> Position -> IO Position
physicalPosition board logicalPosition = do
  (Dir d, bounds) <- boardParams board
  return (throughRotation d bounds logicalPosition)

logicalBounds :: Game Position
logicalBounds =
  game $ \board -> do
    (Dir d, (x, y)) <- boardParams board
    return $ case d of
      U -> (x, y)
      L -> (fromIntegral y, fromIntegral x)
      R -> (fromIntegral y, fromIntegral x)
      D -> (x, y)

allPositions :: Game (NonEmpty (CoordX, NonEmpty CoordY))
allPositions = do
  (x_max, y_max) <- logicalBounds
  when (y_max < 1) $ error "allPositions: game board has no rows"
  when (x_max < 1) $ error "allPositions: game board has no columns"
  return . NE.fromList $
    map (\x -> (x, NE.fromList $ range (1, y_max)))
        (range (1, x_max))

inBoard :: Position -> Game Bool
inBoard p = do
  bounds <- logicalBounds
  return (inRange ((1,1), bounds) p)

under :: Position -> Game (Maybe Position)
under (x, y) =
  inBoard (x, y + 1) >>= return . \case
    True  -> Just (x, y + 1)
    False -> Nothing

playable :: Position -> Game Bool
playable here =
  getPosition here >>= \case
    Just _  -> return False
    Nothing -> under here >>= \case
      Nothing -> return True
      Just below ->
        getPosition below >>= \case
          Nothing -> return False
          Just _  -> return True

getPosition :: Position -> Game (Maybe Piece)
getPosition p =
  game $ \b@(Board _ locations) ->
    readArray locations =<< physicalPosition b p

unsafePlay :: Piece -> Position -> Game ()
unsafePlay piece p =
  game $ \b@(Board _ locations) ->
    flip (writeArray locations) (Just piece) =<< physicalPosition b p

available :: Game [(CoordX, NonEmpty CoordY)]
available = do
  positions <- allPositions
  fmap filterEmptyCols $
    forM positions $ \(x, ys) ->
      (x,) <$> filterM (playable . (x,)) (toList ys)
  where
    filterEmptyCols
      :: NonEmpty (CoordX, [CoordY]) -> [(CoordX, NonEmpty CoordY)]
    filterEmptyCols =
      mapMaybe (\(x, col) -> (x,) <$> nonEmpty col). toList


forPositions :: (Position -> Game r) -> Game [r]
forPositions f = do
  positions <- allPositions
  fmap concat . forM positions $ \(x, ys) ->
    fmap toList . forM ys $ \y -> f (x, y)

-- Picking a position

-- TODO: make non-selected columns also zippers

data Picking
  = PickCol
      [(CoordX, NonEmpty CoordY)]
       (CoordX, PickRow)
      [(CoordX, NonEmpty CoordY)]
    deriving (Eq, Ord, Show)

data PickRow
  = PickRow
      [CoordY]
       CoordY
      [CoordY]
    deriving (Eq, Ord, Show)

pickRow :: NonEmpty CoordY -> PickRow
pickRow (NE.reverse -> c :| cs)  =
  PickRow cs c []

unPickRow :: PickRow -> NonEmpty CoordY
unPickRow (PickRow ds y us)
  | [      ] <- ds =
      NE.reverse $ y  :| us
  | d' : ds' <- ds =
      NE.reverse $ d' :| (ds' ++ [y] ++ us)

pick :: NonEmpty (CoordX, NonEmpty CoordY) -> Picking
pick ((x, col) :| rs) =
  PickCol [] (x, pickRow col) rs

movePickRow :: Cardinal Vertical -> PickRow -> PickRow
movePickRow dir rowPicking@(PickRow ds y us)
  | U <- dir, [] <- us = rowPicking
  | D <- dir, [] <- ds = rowPicking
  | U <- dir, y' : us' <- us =
      PickRow (y : ds) y' us'
  | D <- dir, y' : ds' <- ds =
      PickRow ds' y' (y : us)

movePick :: Cardinal d -> Picking -> Picking
movePick dir picking@(PickCol ls (x, col) rs)
  | U <- dir = PickCol ls (x, movePickRow dir col) rs
  | D <- dir = PickCol ls (x, movePickRow dir col) rs
  | L <- dir, [] <- ls = picking
  | R <- dir, [] <- rs = picking
  | L <- dir, (x', col') : ls' <- ls =
      PickCol ls' (x', pickRow col') ((x, unPickRow col) : rs)
  | R <- dir, (x', col') : rs' <- rs =
      PickCol ((x, unPickRow col) : ls) (x', pickRow col') rs'

getPick :: Picking -> Position
getPick (PickCol _ (x, PickRow _ y _) _) = (x, y)

-- TODO: Use module abstraction to make it impossible to play somewhere that is
-- not available. Don't export Picking constructors, just movePick and getPick.
-- Then, moveWith :: (Picking -> Game Picking) -> Game () makes a move (if there
-- is an available move -- if not, doesn't do anything).

-- Translating board coordinates to print them

forPrint :: Point -> Position -> Point
forPrint (x', y') (CoordX x, CoordY y) =
  (3 + (x - 1) * 4 + x', 1 + (y - 1) * 2 + y')

-- Drawing board elements

borders :: Origin -> Position -> Drawing'
borders origin (forPrint origin -> (x, y)) =
  box (Line Double) origin (2 + x, 1 + y)

playerPiece :: Origin -> Position -> Piece -> Drawing'
playerPiece origin (forPrint origin -> (x, y)) player =
  text (x, y) False (show player)

dot :: Origin -> Position -> Drawing'
dot origin (forPrint origin -> point) =
  text point False "·"

hole :: Origin -> Position -> Drawing'
hole origin (forPrint origin -> point) =
  text (move 1 L point) True "( )"

bracketed :: Origin -> Position -> Drawing'
bracketed origin (forPrint origin -> point) =
  text (move 1 L point) False "[ ]"

dropLine :: Origin -> Thickness -> Position -> Drawing'
dropLine origin thickness (forPrint origin -> (x, y)) =
  stroke (Line (Dashed thickness)) (x, 1) Nothing D (fromIntegral y - 1)

acrossLine :: Origin -> Thickness -> Position -> Drawing'
acrossLine origin thickness (forPrint origin -> (x, y)) =
  stroke (Line (Dashed thickness)) (1, y) Nothing R (fromIntegral x + 1)

placing :: Origin -> Piece -> Position -> Drawing'
placing origin piece position =
  mconcat
    [ dropLine origin Thin position
    , hole origin position
    , playerPiece origin position piece
    ]

-- Effectful drawing

drawBorders :: Origin -> Game Drawing'
drawBorders origin =
  borders origin <$> logicalBounds

drawPieces :: Origin -> Game Drawing'
drawPieces origin =
  fmap mconcat . forPositions $ \p ->
    getPosition p >>= return . \case
      Nothing    -> mempty
      Just piece -> playerPiece origin p piece

drawGrid :: Origin -> Game Drawing'
drawGrid origin =
  fmap mconcat . forPositions $ \p ->
    return (dot origin p)
