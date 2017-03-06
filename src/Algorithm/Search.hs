{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}

-- | This module contains a collection of generalized graph search algorithms,
-- for when you don't want to explicitly represent your data as a graph. The
-- general idea is to provide these algorithms with a way of generating "next"
-- states (and associated information), a way of determining when you have found
-- a solution, a way of pruning out "dead ends", and an initial state.
module Algorithm.Search (
  bfs,
  dfs,
  dijkstra,
  aStar
  ) where

import qualified Data.Map as Map
import qualified Data.Sequence as Seq
import qualified Data.Set as Set
import qualified Data.List as List


-- | @bfs next solved prunes initial@ performs a breadth-first search over a set
-- of states, starting with @initial@, generating neighboring states with
-- @next@, and pruning out any state for which a function in @prunes@ returns
-- 'True'. It returns a path to a state for which @solved@ returns 'True'.
-- Returns 'Nothing' if no path is possible.
--
-- === Example: Making change problem
--
-- >>> :{
-- countChange target = bfs add_one_coin (== target) [(> target)] 0
--   where
--     add_one_coin amt = map (+ amt) coins
--     coins = [25, 10, 5, 1]
-- :}
--
-- >>> countChange 67
-- Just [25,50,60,65,66,67]
bfs :: Ord state =>
  (state -> [state])
  -- ^ Function to generate "next" states given a current state
  -> (state -> Bool)
  -- ^ Predicate to determine if solution found. 'bfs' returns a path to the
  -- first state for which this predicate returns 'True'.
  -> [state -> Bool]
  -- ^ List of ways to prune search. These are predicates which, if 'True', are
  -- considered to indicate a "dead end".
  -> state
  -- ^ Initial state
  -> Maybe [state]
  -- ^ First path found to a state matching the predicate, or 'Nothing' if no
  -- such path exists.
bfs =
  -- BFS is a generalized search using a queue, which directly compares states,
  -- and which always uses the first path found to a state
  generalizedSearch Seq.empty id (\_ _ -> False)


-- | @dfs next solved prunes initial@ performs a depth-first search over a set
-- of states, starting with @initial@, generating neighboring states with
-- @next@, and pruning out any state for which a function in @prunes@ returns
-- 'True'. It returns a depth-first path to a state for which @solved@
-- returns 'True'. Returns 'Nothing' if no path is possible.
--
-- === Example: Simple directed graph search
--
-- >>> import qualified Data.Map as Map
--
-- >>> graph = Map.fromList [(1, [2, 3]), (2, [4]), (3, [4]), (4, [])]
--
-- >>> dfs (graph Map.!) (== 4) [] 1
-- Just [3,4]
dfs :: Ord state =>
  (state -> [state])
  -- ^ Function to generate "next" states given a current state
  -> (state -> Bool)
  -- ^ Predicate to determine if solution found. 'dfs' returns a path to the
  -- first state for which this predicate returns 'True'.
  -> [state -> Bool]
  -- ^ List of ways to prune search. These are predicates which, if 'True', are
  -- considered to indicate a "dead end".
  -> state
  -- ^ Initial state
  -> Maybe [state]
  -- ^ First path found to a state matching the predicate, or 'Nothing' if no
  -- such path exists.
dfs =
  -- DFS is a generalized search using a stack, which directly compares states,
  -- and which always uses the first path found to a state
  generalizedSearch [] id (\_ _ -> False)


-- | @dijkstra next solved prunes initial@ performs a shortest-path search over
-- a set of states using Dijkstra's algorithm, starting with @initial@,
-- generating neighboring states and their incremental costs with @next@, and
-- pruning out any state for which a function in @prunes@ returns 'True'.
-- This will find the least-costly path from an initial state to a state for
-- which @solved@ returns 'True'. Returns 'Nothing' if no path to a solved state
-- is possible.
--
-- === Example: Making change problem, with a twist
--
-- >>> :{
-- -- Twist: dimes have a face value of 10 cents, but are actually rare
-- -- misprints which are worth 10 dollars
-- countChange target = dijkstra add_one_coin (== target) [(> target)] 0
--   where
--     add_one_coin amt =
--       map (\(true_val, face_val) -> (true_val, face_val + amt)) coin_values
--     coin_values = [(25, 25), (1000, 10), (5, 5), (1, 1)]
-- :}
--
-- >>> countChange 67
-- Just (67,[(1,1),(1,2),(5,7),(5,12),(5,17),(25,42),(25,67)])
dijkstra :: (Num cost, Ord cost, Ord state) =>
  (state -> [(cost, state)])
  -- ^ Function to generate list of incremental cost and neighboring states
  -- given the current state
  -> (state -> Bool)
  -- ^ Predicate to determine if solution found. 'dijkstra' returns the shortest
  -- path to the first state for which this predicate returns 'True'.
  -> [state -> Bool]
  -- ^ List of ways to prune search. These are predicates which, if 'True', are
  -- considered to indicate a "dead end".
  -> state
  -- ^ Initial state
  -> Maybe (cost, [(cost, state)])
  -- (Total cost, [(incremental cost, step)]) for the first path found which
  -- satisfies the given predicate
dijkstra next solved prunes initial =
  -- Dijkstra's algorithm can be viewed as a generalized search, with the search
  -- container being a heap, with the states being compared without regard to
  -- cost, with the shorter paths taking precedence over longer ones, and with
  -- the stored state being (cost so far, state).
  -- This implementation makes that transformation, then transforms that result
  -- back into the desired result from @dijkstra@
  unpack <$>
    generalizedSearch emptyLIFOHeap snd better next' (solved . snd)
      (map (. snd) prunes) (0, initial)
  where
    better [] _ = False
    better _ [] = True
    better ((cost_a, _):_) ((cost_b, _):_) = cost_b < cost_a
    next' (cost, st) = map (\(incr, new_st) -> (incr + cost, new_st)) (next st)
    unpack packed_states =
      let costs = map fst packed_states
          incremental_costs = zipWith (-) costs (0:costs)
          states = map snd packed_states
      in (if null packed_states then 0 else fst . last $ packed_states,
          zip incremental_costs states)


-- | @aStar next solved prunes initial@ performs a best-first search using
-- the A* search algorithm, starting with the state @initial@, generating
-- neighboring states, their cost, and an estimate of the remaining cost with
-- @next@, and pruning out any state for which a function in @prunes@ returns
-- 'True'. This returns a path to a state for which @solved@ returns 'True'.
-- If the estimate is strictly a lower bound on the remaining cost to reach a
-- @solved@ state, then the returned path is the shortest path. Returns
-- 'Nothing' if no path to a @solved@ state is possible.
--
-- === Example: Path finding in taxicab geometry
--
-- >>> :{
-- neighbors (x, y) = [(x, y + 1), (x - 1, y), (x + 1, y), (x, y - 1)]
-- dist (x1, y1) (x2, y2) = abs (y2 - y1) + abs (x2 - x1)
-- nextTowards dest pos = map (\p -> (1, dist p dest, p)) (neighbors pos)
-- :}
--
-- >>> aStar (nextTowards (0, 2)) (== (0, 2)) [(== (0, 1))] (0, 0)
-- Just (4,[(1,(1,0)),(1,(1,1)),(1,(1,2)),(1,(0,2))])
aStar :: (Num cost, Ord cost, Ord state) =>
  (state -> [(cost, cost, state)])
  -- ^ Function which, when given the current state, produces a list whose
  -- elements are (incremental cost to reach neighboring state,
  -- estimate on remaining cost from said state, said state).
  -> (state -> Bool)
  -- ^ Predicate to determine if solution found. 'aStar' returns the shortest
  -- path to the first state for which this predicate returns 'True'.
  -> [state -> Bool]
  -- ^ List of ways to prune search. These are predicates which, if 'True', are
  -- considered to indicate a "dead end".
  -> state
  -- ^ Initial state
  -> Maybe (cost, [(cost, state)])
  -- (Total cost, [(incremental cost, step)]) for the first path found which
  -- satisfies the given predicate
aStar next found prunes initial =
  -- The idea of this implementation is that we can use the same machinery as
  -- Dijkstra's algorithm, by changing Dijsktra's cost function to be
  -- (incremental cost + lower bound remaining cost). We'd still like to be able
  -- to return the list of incremental costs, so we modify the internal state to
  -- be (incremental cost to state, state). Then at the end we undo this
  -- transformation
  unpack <$> dijkstra next' (found . snd) (map (. snd) prunes) (0, initial)
  where
    next' (_, st) = map pack (next st)
    pack (incr, est, new_st) = (incr + est, (incr, new_st))
    unpack (_, packed_states) =
      let unpacked_states = map snd packed_states
      in (sum (map fst unpacked_states), unpacked_states)


-- | A 'SearchState' represents the state of a generalized search at a given
-- point in an algorithms execution. The advantage of this abstraction is that
-- it can be used for things like bidirectional searches, where you want to
-- stop and start a search part-way through.
data SearchState container stateKey state = SearchState {
  current :: state,
  queue :: container,
  visited :: Set.Set stateKey,
  paths :: Map.Map stateKey [state]
  }


-- | 'nextSearchState' moves from one 'searchState' to the next in the
-- generalized search algorithm
nextSearchState :: (SearchContainer f state, Ord stateKey) =>
  ([state] -> [state] -> Bool)
  -> (state -> stateKey)
  -> (state -> [state])
  -> [state -> Bool]
  -> SearchState f stateKey state
  -> Maybe (SearchState f stateKey state)
nextSearchState better mk_key next prunes old = do
  new_state <- mk_search_state <$> pop new_queue
  if mk_key (current new_state) `Set.member` visited old
    then nextSearchState better mk_key next prunes new_state
    else Just new_state
  where
    mk_search_state (new_current, remaining_queue) = SearchState {
      current = new_current,
      queue = remaining_queue,
      visited = Set.insert (mk_key new_current) (visited old),
      paths = new_paths
      }
    new_states = next (current old)
    (new_queue, new_paths) =
      List.foldl' update_queue_paths (queue old, paths old) new_states
    update_queue_paths (old_queue, old_paths) st =
      if mk_key st `Set.member` visited old || any ($ st) prunes
      then (old_queue, old_paths)
      else
        case Map.lookup (mk_key st) old_paths of
          Just old_path ->
            if better old_path (st : steps_so_far)
            then (q', ps')
            else (old_queue, old_paths)
          Nothing -> (q', ps')
        where
          steps_so_far = paths old Map.! mk_key (current old)
          q' = push old_queue st
          ps' = Map.insert (mk_key st) (st : steps_so_far) old_paths


-- | Workhorse simple search algorithm, generalized over search container
-- and path-choosing function. The idea here is that many search algorithms are
-- at their core the same, with these details substituted. By writing these
-- searches in terms of this function, we reduce the chances of errors sneaking
-- into each separate implementation.
generalizedSearch :: (SearchContainer container state, Ord stateKey) =>
  container
  -- ^ Empty 'SearchContainer'
  -> (state -> stateKey)
  -- ^ Function to turn a @state@ into a key by which states will be compared
  -- when determining whether a state has be enqueued and / or visited
  -> ([state] -> [state] -> Bool)
  -- ^ Function @better old new@, which when given a choice between an @old@ and
  -- a @new@ path to a state, returns True when @new@ is a "better" path than
  -- old and should thus be inserted
  -> (state -> [state])
  -- ^ Function to generate "next" states given a current state
  -> (state -> Bool)
  -- ^ Predicate to determine if solution found. 'search' returns a path to the
  -- first state for which this predicate returns 'True'.
  -> [state -> Bool]
  -- ^ List of ways to prune search. These are predicates which, if 'True', are
  -- considered to indicate a "dead end".
  -> state
  -- ^ Initial state
  -> Maybe [state]
  -- ^ First path found to a state matching the predicate, or 'Nothing' if no
  -- such path exists.
generalizedSearch empty mk_key better next solved prunes initial =
  let get_steps search_st = paths search_st Map.! mk_key (current search_st)
  in fmap (reverse . get_steps)
     . findIterate (solved . current) (nextSearchState better mk_key next prunes)
     $ SearchState initial empty (Set.singleton $ mk_key initial)
       (Map.singleton (mk_key initial) [])

newtype LIFOHeap k a = LIFOHeap (Map.Map k [a])

emptyLIFOHeap :: LIFOHeap k a
emptyLIFOHeap = LIFOHeap Map.empty

-- | The 'SearchContainer' class abstracts the idea of a container to be used in
-- 'generalizedSearch'
class SearchContainer container elem | container -> elem where
  pop :: container -> Maybe (elem, container)
  push :: container -> elem -> container

instance SearchContainer (Seq.Seq a) a where
  pop s =
    case Seq.viewl s of
      Seq.EmptyL -> Nothing
      (x Seq.:< xs) -> Just (x, xs)
  push s a = s Seq.|> a

instance SearchContainer [a] a where
  pop list =
    case list of
      [] -> Nothing
      (x : xs) -> Just (x, xs)
  push list a = a : list

instance Ord k => SearchContainer (LIFOHeap k a) (k, a) where
  pop (LIFOHeap inner)
    | Map.null inner = Nothing
    | otherwise = case Map.findMin inner of
      (_, []) -> bugReport "Unexpectedly empty heap element."
      (k, [a]) -> Just ((k, a), LIFOHeap $ Map.deleteMin inner)
      (k, a : _) -> Just ((k, a), LIFOHeap $ Map.updateMin (Just . tail) inner)
  push (LIFOHeap inner) (k, a) = LIFOHeap $ Map.insertWith (++) k [a] inner


-- | @findIterate found next initial@ takes an initial seed value and applies
-- @next@ to it until either @found@ returns True or @next@ returns @Nothing@
findIterate :: (a -> Bool) -> (a -> Maybe a) -> a -> Maybe a
findIterate found next initial
  | found initial = Just initial
  | otherwise = next initial >>= findIterate found next

-- | Use this to mark impossible situations
bugReport :: String -> a
bugReport msg = error $
  msg ++ " This is a bug. Please file an issue at \
         \https://github.com/devonhollowood/search-algorithms"
