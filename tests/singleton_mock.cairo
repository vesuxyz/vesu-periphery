use starknet::{ContractAddress};

use vesu::data_model::{ModifyPositionParams, UpdatePositionResponse, Position};

#[starknet::interface]
pub trait ISingletonMock<TContractState> {
    fn position(
        ref self: TContractState,
        pool_id: felt252,
        collateral_asset: ContractAddress,
        debt_asset: ContractAddress,
        user: ContractAddress
    ) -> Position;
    fn modify_position(
        ref self: TContractState, modify_position_params: ModifyPositionParams
    ) -> UpdatePositionResponse;
}

#[starknet::contract]
pub mod SingletonMock {
    use starknet::{ContractAddress, get_block_timestamp};

    use vesu::{
        data_model::{
            ModifyPositionParams, Amount, AmountType, AmountDenomination, UpdatePositionResponse, Position, AssetConfig
        },
        packing::{PositionPacking},
        common::{i257, i257_new, deconstruct_collateral_amount, deconstruct_debt_amount, calculate_collateral, calculate_debt},
        units::{SCALE, SCALE_128}
    };

    use super::{ISingletonMock};

    #[storage]
    struct Storage {
        positions: LegacyMap<(felt252, ContractAddress, ContractAddress, ContractAddress), Position>
    }

    #[abi(embed_v0)]
    impl SingletonMockImpl of ISingletonMock<ContractState> {
        fn position(
            ref self: ContractState,
            pool_id: felt252,
            collateral_asset: ContractAddress,
            debt_asset: ContractAddress,
            user: ContractAddress
        ) -> Position {
            self.positions.read(
                (pool_id, collateral_asset, debt_asset, user)
            )
        }

        fn modify_position(
            ref self: ContractState, modify_position_params: ModifyPositionParams
        ) -> UpdatePositionResponse {
            let asset_config = AssetConfig {
                total_collateral_shares: SCALE,
                total_nominal_debt: SCALE,
                reserve: SCALE,
                max_utilization: SCALE,
                floor: 0,
                scale: SCALE,
                is_legacy: false,
                last_updated: get_block_timestamp(),
                last_rate_accumulator: SCALE,
                last_full_utilization_rate: SCALE,
                fee_rate: 0,
            };

            let mut position = self
                .positions
                .read(
                    (
                        modify_position_params.pool_id,
                        modify_position_params.collateral_asset,
                        modify_position_params.debt_asset,
                        modify_position_params.user
                    )
                );

            let (mut collateral_delta, mut collateral_shares_delta) = deconstruct_collateral_amount(
                modify_position_params.collateral, position, asset_config,
            );

            if collateral_shares_delta > i257_new(0, false) {
                position.collateral_shares += collateral_shares_delta.abs;
            } else if collateral_shares_delta < i257_new(0, false) {
                if collateral_shares_delta.abs > position.collateral_shares {
                    collateral_shares_delta =
                        i257_new(
                            position.collateral_shares, collateral_shares_delta.is_negative
                        );
                    collateral_delta =
                        i257_new(
                            calculate_collateral(collateral_shares_delta.abs, asset_config, false),
                            collateral_delta.is_negative
                        );
                }
                position.collateral_shares -= collateral_shares_delta.abs;
            }

            let (mut debt_delta, mut nominal_debt_delta) = deconstruct_debt_amount(
                modify_position_params.debt, position, asset_config.last_rate_accumulator, asset_config.scale
            );

            if nominal_debt_delta > i257_new(0, false) {
                position.nominal_debt += nominal_debt_delta.abs;
            } else if nominal_debt_delta < i257_new(0, false) {
                if nominal_debt_delta.abs > position.nominal_debt {
                    nominal_debt_delta =
                        i257_new(position.nominal_debt, nominal_debt_delta.is_negative);
                    debt_delta =
                        i257_new(
                            calculate_debt(
                                nominal_debt_delta.abs,
                                asset_config.last_rate_accumulator,
                                asset_config.scale,
                                true
                            ),
                            debt_delta.is_negative
                        );
                }
                position.nominal_debt -= nominal_debt_delta.abs;
            }

            self
                .positions
                .write(
                    (
                        modify_position_params.pool_id,
                        modify_position_params.collateral_asset,
                        modify_position_params.debt_asset,
                        modify_position_params.user,
                    ),
                    position
                );

            UpdatePositionResponse {
                collateral_delta,
                collateral_shares_delta,
                debt_delta,
                nominal_debt_delta,
                bad_debt: 0
            }
        }
    }
}
