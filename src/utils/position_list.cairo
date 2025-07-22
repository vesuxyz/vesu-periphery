use core::hash::LegacyHash;
use core::num::traits::zero::Zero;
use starknet::ContractAddress;

#[derive(PartialEq, Copy, Drop, starknet::Store)]
pub struct Position {
    pub pool_id: felt252,
    pub collateral_asset: ContractAddress,
    pub debt_asset: ContractAddress,
}

pub trait PositionTrait {
    fn hash(self: @Position) -> felt252;
}

impl PositionImpl of PositionTrait {
    fn hash(self: @Position) -> felt252 {
        if self.is_zero() {
            return Zero::zero();
        }
        PositionLegacyHash::hash(0, *self)
    }
}

impl PositionZero of Zero<Position> {
    fn zero() -> Position {
        Position { pool_id: 0, collateral_asset: Zero::zero(), debt_asset: Zero::zero() }
    }
    fn is_zero(self: @Position) -> bool {
        *self.pool_id == 0 && self.collateral_asset.is_zero() && self.debt_asset.is_zero()
    }
    fn is_non_zero(self: @Position) -> bool {
        !self.is_zero()
    }
}

impl PositionLegacyHash of LegacyHash<Position> {
    fn hash(state: felt252, value: Position) -> felt252 {
        let mut data: Array<felt252> = ArrayTrait::new();
        data.append(value.pool_id.into());
        data.append(value.collateral_asset.into());
        data.append(value.debt_asset.into());
        core::poseidon::poseidon_hash_span(data.span())
    }
}

#[starknet::component]
pub mod position_list_component {
    use core::num::traits::zero::Zero;
    use starknet::storage::{Map, StorageMapReadAccess, StorageMapWriteAccess};
    use super::{Position, PositionTrait};

    #[storage]
    pub struct Storage {
        // A list of positions
        // hash(position) -> next position
        positions: Map<felt252, Position>,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {}

    #[generate_trait]
    pub impl PositionListTrait<
        TContractState, +HasComponent<TContractState>,
    > of Trait<TContractState> {
        /// Returns true if the list contains the position
        /// Constant computation cost if `position` is in fact in the list AND it's not the last
        /// one.
        /// Otherwise cost increases with the list size.
        fn contains(self: @ComponentState<TContractState>, position: Position) -> bool {
            if position == Zero::zero() {
                return false;
            }
            let next_position = self.positions.read(position.hash());
            if next_position != Zero::zero() {
                return true;
            }
            // check if its the last
            let last_position = self.last();

            last_position == position
        }

        /// Returns the next position in the list or Zero if the position is the last one
        fn next(self: @ComponentState<TContractState>, position: Position) -> Position {
            self.positions.read(position.hash())
        }

        /// Returns the position before `position` or Zero if the position is the first one
        fn previous(self: @ComponentState<TContractState>, position: Position) -> Position {
            self.find_position_before(position)
        }

        /// Adds a position to the beginning of the list
        fn push_front(ref self: ComponentState<TContractState>, position_to_add: Position) {
            assert!(position_to_add != Zero::zero(), "cannot-push-zero");
            let first = self.first();
            if first != Zero::zero() {
                self.positions.write(position_to_add.hash(), first);
            }
            self.positions.write(Zero::zero(), position_to_add);
        }

        /// Removes a position from the list. Reverts if the position is not found. Cost increases
        /// with the list size.
        fn remove(ref self: ComponentState<TContractState>, position: Position) {
            assert!(position != Zero::zero(), "cannot-remove-zero");
            // position pointer set to 0, Previous pointer set to the next in the list
            let previous_position = self.find_position_before(position);
            let next_position = self.positions.read(position.hash());

            self.positions.write(previous_position.hash(), next_position);

            if next_position != Zero::zero() {
                // Removing an position in the middle
                self.positions.write(position.hash(), Zero::zero());
            }
        }

        /// Returns the first position or zero if list is empty
        fn first(self: @ComponentState<TContractState>) -> Position {
            self.positions.read(Zero::zero())
        }

        /// Return the last position or zero if list is empty. Cost increases with the list size.
        fn last(self: @ComponentState<TContractState>) -> Position {
            let mut current_position = self.positions.read(Zero::zero());
            loop {
                let next_position = self.positions.read(current_position.hash());
                if next_position == Zero::zero() {
                    break current_position;
                }
                current_position = next_position;
            }
        }

        /// Returns all positions in the list. Cost increases with the list size.
        fn all(self: @ComponentState<TContractState>) -> Array<Position> {
            let mut current_position = self.positions.read(Zero::zero());
            let mut positions = array![];
            while current_position != Zero::zero() {
                positions.append(current_position);
                current_position = self.positions.read(current_position.hash());
            }
            positions
        }
    }

    #[generate_trait]
    impl Private<TContractState, +HasComponent<TContractState>> of PrivateTrait<TContractState> {
        /// Returns the position before `position_after` or Zero if the position is the first one.
        /// Reverts if `position_after` is not found
        /// Cost increases with the list size
        fn find_position_before(
            self: @ComponentState<TContractState>, position_after: Position,
        ) -> Position {
            let mut current_position: Position = Zero::zero();
            loop {
                let next_position = self.positions.read(current_position.hash());
                assert!(next_position != Zero::zero(), "cannot-find-position-before");

                if next_position == position_after {
                    break current_position;
                }
                current_position = next_position;
            }
        }
    }
}
