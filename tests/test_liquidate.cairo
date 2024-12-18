use starknet::{ContractAddress};

#[starknet::interface]
trait IStarkgateERC20<TContractState> {
    fn permissioned_mint(ref self: TContractState, account: ContractAddress, amount: u256);
}

#[cfg(test)]
mod Test_896150_Liquidate {
    use snforge_std::{
        start_prank, stop_prank, start_warp, stop_warp, CheatTarget, load, store, prank, CheatSpan
    };
    use starknet::{
        ContractAddress, contract_address_const, get_block_timestamp, get_caller_address,
        get_contract_address
    };
    use core::num::traits::{Zero};
    use ekubo::{
        interfaces::{
            core::{ICoreDispatcher, ICoreDispatcherTrait, ILocker, SwapParameters},
            erc20::{IERC20Dispatcher, IERC20DispatcherTrait}
        },
        types::{i129::{i129_new, i129Trait}, keys::{PoolKey},}
    };
    use vesu::{
        units::{SCALE, SCALE_128},
        data_model::{Amount, AmountType, AmountDenomination, ModifyPositionParams},
        singleton::{ISingletonDispatcher, ISingletonDispatcherTrait},
        test::{
            setup::{deploy_with_args, deploy_contract},
            mock_oracle::{IMockPragmaOracleDispatcher, IMockPragmaOracleDispatcherTrait}
        },
        extension::interface::{IExtensionDispatcher, IExtensionDispatcherTrait}
    };
    use vesu_periphery::liquidate::{
        ILiquidateDispatcher, ILiquidateDispatcherTrait, LiquidateParams, LiquidateResponse
    };

    use vesu_periphery::swap::{RouteNode, TokenAmount, Swap};

    use super::{IStarkgateERC20Dispatcher, IStarkgateERC20DispatcherTrait};

    const MIN_SQRT_RATIO_LIMIT: u256 = 18446748437148339061;
    const MAX_SQRT_RATIO_LIMIT: u256 = 6277100250585753475930931601400621808602321654880405518632;

    struct TestConfig {
        ekubo: ICoreDispatcher,
        singleton: ISingletonDispatcher,
        liquidate: ILiquidateDispatcher,
        pool_id: felt252,
        pool_key: PoolKey,
        pool_key_2: PoolKey,
        pool_key_3: PoolKey,
        pool_key_4: PoolKey,
        eth: IERC20Dispatcher,
        usdc: IERC20Dispatcher,
        usdt: IERC20Dispatcher,
        user: ContractAddress,
    }

    fn setup() -> TestConfig {
        let ekubo = ICoreDispatcher {
            contract_address: contract_address_const::<
                0x00000005dd3D2F4429AF886cD1a3b08289DBcEa99A294197E9eB43b0e0325b4b
            >()
        };
        let singleton = ISingletonDispatcher {
            contract_address: contract_address_const::<
                0x2545b2e5d519fc230e9cd781046d3a64e092114f07e44771e0d719d148725ef
            >()
        };
        let liquidate = ILiquidateDispatcher {
            contract_address: deploy_with_args(
                "Liquidate",
                array![ekubo.contract_address.into(), singleton.contract_address.into()]
            )
        };

        let eth = IERC20Dispatcher {
            contract_address: contract_address_const::<
                0x049d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7
            >()
        };
        let usdc = IERC20Dispatcher {
            contract_address: contract_address_const::<
                0x053c91253bc9682c04929ca02ed00b3e423f6710d2ee7e0d5ebb06f3ecf368a8
            >()
        };
        let usdt = IERC20Dispatcher {
            contract_address: contract_address_const::<
                0x068f5c6a61780768455de69077e07e89787839bf8166decfbf92b645209c0fb8
            >()
        };
        let strk = IERC20Dispatcher {
            contract_address: contract_address_const::<
                0x4718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d
            >()
        };

        let pool_id = 2198503327643286920898110335698706244522220458610657370981979460625005526824;

        let pool_key = PoolKey {
            token0: eth.contract_address,
            token1: usdc.contract_address,
            fee: 170141183460469235273462165868118016,
            tick_spacing: 1000,
            extension: contract_address_const::<0x0>()
        };

        let pool_key_2 = PoolKey {
            token0: usdc.contract_address,
            token1: usdt.contract_address,
            fee: 8507159232437450533281168781287096,
            tick_spacing: 25,
            extension: contract_address_const::<0x0>()
        };

        let pool_key_3 = PoolKey {
            token0: strk.contract_address,
            token1: usdc.contract_address,
            fee: 34028236692093847977029636859101184,
            tick_spacing: 200,
            extension: contract_address_const::<0x0>()
        };

        let pool_key_4 = PoolKey {
            token0: strk.contract_address,
            token1: eth.contract_address,
            fee: 34028236692093847977029636859101184,
            tick_spacing: 200,
            extension: contract_address_const::<0x0>()
        };

        let user = get_contract_address();

        let loaded = load(usdc.contract_address, selector!("permitted_minter"), 1);
        let minter: ContractAddress = (*loaded[0]).try_into().unwrap();
        start_prank(CheatTarget::One(usdc.contract_address), minter);
        IStarkgateERC20Dispatcher { contract_address: usdc.contract_address }
            .permissioned_mint(user, 100000_000_000);
        stop_prank(CheatTarget::One(usdc.contract_address));

        let loaded = load(usdt.contract_address, selector!("permitted_minter"), 1);
        let minter: ContractAddress = (*loaded[0]).try_into().unwrap();
        start_prank(CheatTarget::One(usdt.contract_address), minter);
        IStarkgateERC20Dispatcher { contract_address: usdt.contract_address }
            .permissioned_mint(user, 100000_000_000);
        stop_prank(CheatTarget::One(usdt.contract_address));

        let test_config = TestConfig {
            ekubo,
            singleton,
            liquidate,
            pool_id,
            pool_key,
            pool_key_2,
            pool_key_3,
            pool_key_4,
            eth,
            usdc,
            usdt,
            user
        };

        test_config
    }

    #[test]
    #[available_gas(20000000)]
    #[fork("Mainnet")]
    fn test_liquidate_position_full_liquidation_multi_swap() {
        let TestConfig { singleton, liquidate, pool_id, pool_key, eth, usdc, user, .. } = setup();

        let params = ModifyPositionParams {
            pool_id,
            collateral_asset: usdc.contract_address,
            debt_asset: eth.contract_address,
            user: user,
            collateral: Amount {
                amount_type: AmountType::Delta,
                denomination: AmountDenomination::Assets,
                value: 14000_000_000.into()
            },
            debt: Amount {
                amount_type: AmountType::Delta,
                denomination: AmountDenomination::Assets,
                value: (3 * SCALE).into()
            },
            data: ArrayTrait::new().span()
        };

        start_prank(CheatTarget::One(usdc.contract_address), user);
        usdc.approve(singleton.contract_address, params.collateral.value.abs);
        stop_prank(CheatTarget::One(usdc.contract_address));

        start_prank(CheatTarget::One(singleton.contract_address), user);
        singleton.modify_position(params);
        stop_prank(CheatTarget::One(singleton.contract_address));

        let (_, collateral, debt) = singleton
            .position(pool_id, usdc.contract_address, eth.contract_address, user);
        assert!(collateral + 1 == params.collateral.value.abs);
        assert!(debt - 1 == params.debt.value.abs);

        let mock_pragma_oracle = IMockPragmaOracleDispatcher {
            contract_address: deploy_contract("MockPragmaOracle")
        };
        mock_pragma_oracle.set_num_sources_aggregated('USDC/USD', 10);
        mock_pragma_oracle.set_price('USDC/USD', SCALE_128 * 8 / 10);
        let extension = singleton.extension(pool_id);
        let price = IExtensionDispatcher { contract_address: extension }
            .price(pool_id, eth.contract_address);
        mock_pragma_oracle.set_num_sources_aggregated('ETH/USD', 10);
        mock_pragma_oracle.set_price('ETH/USD', price.value.try_into().unwrap());

        store(
            extension,
            selector!("oracle_address"),
            array![mock_pragma_oracle.contract_address.into()].span()
        );

        // reduce oracle price

        mock_pragma_oracle.set_price('USDC/USD', SCALE_128 / 2);

        let liquidator = contract_address_const::<'liquidator'>();

        assert!(usdc.balanceOf(liquidator) == 0);

        prank(CheatTarget::One(liquidate.contract_address), liquidator, CheatSpan::TargetCalls(1));

        let response: LiquidateResponse = liquidate
            .liquidate(
                LiquidateParams {
                    pool_id,
                    collateral_asset: usdc.contract_address,
                    debt_asset: eth.contract_address,
                    user,
                    recipient: liquidator,
                    min_collateral_to_receive: collateral,
                    debt_to_repay: 0,
                    liquidate_swap: array![
                        Swap {
                            route: array![
                                RouteNode {
                                    pool_key: pool_key,
                                    sqrt_ratio_limit: MAX_SQRT_RATIO_LIMIT,
                                    skip_ahead: 0
                                }
                            ],
                            token_amount: TokenAmount {
                                token: eth.contract_address, amount: Zero::zero()
                            }
                        }
                    ],
                    liquidate_swap_limit_amount: 8000_000_000,
                    liquidate_swap_weights: array![SCALE_128],
                    withdraw_swap: array![],
                    withdraw_swap_limit_amount: 0,
                    withdraw_swap_weights: array![]
                }
            );

        assert!(response.liquidated_collateral == collateral);
        assert!(response.repaid_debt == debt);
        assert!(
            response.residual_collateral != 0
                && response.residual_collateral == usdc.balanceOf(liquidator)
        );
        assert!(eth.balanceOf(liquidate.contract_address) == 0);
        assert!(usdc.balanceOf(liquidate.contract_address) == 0);

        let (position, _, _) = singleton
            .position(pool_id, usdc.contract_address, eth.contract_address, user);
        assert!(position.nominal_debt == 0);
    }

    #[test]
    #[available_gas(20000000)]
    #[fork("Mainnet")]
    fn test_liquidate_position_full_liquidation_multi_swap_no_bad_debt() {
        let TestConfig { singleton, liquidate, pool_id, pool_key, eth, usdc, user, .. } = setup();

        let params = ModifyPositionParams {
            pool_id,
            collateral_asset: usdc.contract_address,
            debt_asset: eth.contract_address,
            user: user,
            collateral: Amount {
                amount_type: AmountType::Delta,
                denomination: AmountDenomination::Assets,
                value: 14000_000_000.into()
            },
            debt: Amount {
                amount_type: AmountType::Delta,
                denomination: AmountDenomination::Assets,
                value: (3 * SCALE).into()
            },
            data: ArrayTrait::new().span()
        };

        start_prank(CheatTarget::One(usdc.contract_address), user);
        usdc.approve(singleton.contract_address, params.collateral.value.abs);
        stop_prank(CheatTarget::One(usdc.contract_address));

        start_prank(CheatTarget::One(singleton.contract_address), user);
        singleton.modify_position(params);
        stop_prank(CheatTarget::One(singleton.contract_address));

        let (_, collateral, debt) = singleton
            .position(pool_id, usdc.contract_address, eth.contract_address, user);
        assert!(collateral + 1 == params.collateral.value.abs);
        assert!(debt - 1 == params.debt.value.abs);

        let mock_pragma_oracle = IMockPragmaOracleDispatcher {
            contract_address: deploy_contract("MockPragmaOracle")
        };
        mock_pragma_oracle.set_num_sources_aggregated('USDC/USD', 10);
        mock_pragma_oracle.set_price('USDC/USD', SCALE_128 * 8 / 10);
        let extension = singleton.extension(pool_id);
        let price = IExtensionDispatcher { contract_address: extension }
            .price(pool_id, eth.contract_address);
        mock_pragma_oracle.set_num_sources_aggregated('ETH/USD', 10);
        mock_pragma_oracle.set_price('ETH/USD', price.value.try_into().unwrap());

        store(
            extension,
            selector!("oracle_address"),
            array![mock_pragma_oracle.contract_address.into()].span()
        );

        // reduce oracle price

        mock_pragma_oracle.set_price('USDC/USD', SCALE_128 * 8 / 10);

        let liquidator = contract_address_const::<'liquidator'>();

        assert!(usdc.balanceOf(liquidator) == 0);

        prank(CheatTarget::One(liquidate.contract_address), liquidator, CheatSpan::TargetCalls(1));
        let response: LiquidateResponse = liquidate
            .liquidate(
                LiquidateParams {
                    pool_id,
                    collateral_asset: usdc.contract_address,
                    debt_asset: eth.contract_address,
                    user,
                    recipient: liquidator,
                    min_collateral_to_receive: collateral / 2,
                    debt_to_repay: 0,
                    liquidate_swap: array![
                        Swap {
                            route: array![
                                RouteNode {
                                    pool_key: pool_key,
                                    sqrt_ratio_limit: MAX_SQRT_RATIO_LIMIT,
                                    skip_ahead: 0
                                }
                            ],
                            token_amount: TokenAmount {
                                token: eth.contract_address, amount: Zero::zero()
                            }
                        }
                    ],
                    liquidate_swap_limit_amount: 14000_000_000,
                    liquidate_swap_weights: array![SCALE_128],
                    withdraw_swap: array![],
                    withdraw_swap_limit_amount: 0,
                    withdraw_swap_weights: array![]
                }
            );

        assert!(response.liquidated_collateral < collateral);
        assert!(response.repaid_debt == debt);
        assert!(
            response.residual_collateral != 0
                && response.residual_collateral == usdc.balanceOf(liquidator)
        );
        assert!(eth.balanceOf(liquidate.contract_address) == 0);
        assert!(usdc.balanceOf(liquidate.contract_address) == 0);

        let (position, _, _) = singleton
            .position(pool_id, usdc.contract_address, eth.contract_address, user);
        assert!(position.nominal_debt == 0);
    }

    #[test]
    #[available_gas(20000000)]
    #[fork("Mainnet")]
    fn test_liquidate_position_partial_liquidation_multi_swap_no_bad_debt() {
        let TestConfig { singleton, liquidate, pool_id, pool_key, eth, usdc, user, .. } = setup();

        let params = ModifyPositionParams {
            pool_id,
            collateral_asset: usdc.contract_address,
            debt_asset: eth.contract_address,
            user: user,
            collateral: Amount {
                amount_type: AmountType::Delta,
                denomination: AmountDenomination::Assets,
                value: 14000_000_000.into()
            },
            debt: Amount {
                amount_type: AmountType::Delta,
                denomination: AmountDenomination::Assets,
                value: (3 * SCALE).into()
            },
            data: ArrayTrait::new().span()
        };

        start_prank(CheatTarget::One(usdc.contract_address), user);
        usdc.approve(singleton.contract_address, params.collateral.value.abs);
        stop_prank(CheatTarget::One(usdc.contract_address));

        start_prank(CheatTarget::One(singleton.contract_address), user);
        singleton.modify_position(params);
        stop_prank(CheatTarget::One(singleton.contract_address));

        let (_, collateral, debt) = singleton
            .position(pool_id, usdc.contract_address, eth.contract_address, user);
        assert!(collateral + 1 == params.collateral.value.abs);
        assert!(debt - 1 == params.debt.value.abs);

        let mock_pragma_oracle = IMockPragmaOracleDispatcher {
            contract_address: deploy_contract("MockPragmaOracle")
        };
        mock_pragma_oracle.set_num_sources_aggregated('USDC/USD', 10);
        mock_pragma_oracle.set_price('USDC/USD', SCALE_128 * 8 / 10);
        let extension = singleton.extension(pool_id);
        let price = IExtensionDispatcher { contract_address: extension }
            .price(pool_id, eth.contract_address);
        mock_pragma_oracle.set_num_sources_aggregated('ETH/USD', 10);
        mock_pragma_oracle.set_price('ETH/USD', price.value.try_into().unwrap());

        store(
            extension,
            selector!("oracle_address"),
            array![mock_pragma_oracle.contract_address.into()].span()
        );

        // reduce oracle price

        mock_pragma_oracle.set_price('USDC/USD', SCALE_128 * 8 / 10);

        let liquidator = contract_address_const::<'liquidator'>();

        assert!(usdc.balanceOf(liquidator) == 0);

        prank(CheatTarget::One(liquidate.contract_address), liquidator, CheatSpan::TargetCalls(1));

        let response: LiquidateResponse = liquidate
            .liquidate(
                LiquidateParams {
                    pool_id,
                    collateral_asset: usdc.contract_address,
                    debt_asset: eth.contract_address,
                    user,
                    recipient: liquidator,
                    min_collateral_to_receive: collateral / 4,
                    debt_to_repay: debt / 2,
                    liquidate_swap: array![
                        Swap {
                            route: array![
                                RouteNode {
                                    pool_key: pool_key,
                                    sqrt_ratio_limit: MAX_SQRT_RATIO_LIMIT,
                                    skip_ahead: 0
                                }
                            ],
                            token_amount: TokenAmount {
                                token: eth.contract_address, amount: Zero::zero()
                            }
                        }
                    ],
                    liquidate_swap_weights: array![SCALE_128],
                    liquidate_swap_limit_amount: 12000_000_000,
                    withdraw_swap: array![],
                    withdraw_swap_limit_amount: 0,
                    withdraw_swap_weights: array![]
                }
            );

        assert!(response.liquidated_collateral < collateral);
        assert!(response.repaid_debt == debt / 2);
        assert!(
            response.residual_collateral != 0
                && response.residual_collateral == usdc.balanceOf(liquidator)
        );
        assert!(eth.balanceOf(liquidate.contract_address) == 0);
        assert!(usdc.balanceOf(liquidate.contract_address) == 0);

        let (_, _, debt_) = singleton
            .position(pool_id, usdc.contract_address, eth.contract_address, user);
        assert!(debt_ < debt);

        mock_pragma_oracle.set_price('USDC/USD', SCALE_128 * 6 / 10);

        let response: LiquidateResponse = liquidate
            .liquidate(
                LiquidateParams {
                    pool_id,
                    collateral_asset: usdc.contract_address,
                    debt_asset: eth.contract_address,
                    user,
                    recipient: liquidator,
                    min_collateral_to_receive: collateral / 4,
                    debt_to_repay: 0,
                    liquidate_swap: array![
                        Swap {
                            route: array![
                                RouteNode {
                                    pool_key: pool_key,
                                    sqrt_ratio_limit: MAX_SQRT_RATIO_LIMIT,
                                    skip_ahead: 0
                                }
                            ],
                            token_amount: TokenAmount {
                                token: eth.contract_address, amount: Zero::zero()
                            }
                        }
                    ],
                    liquidate_swap_limit_amount: 12000_000_000,
                    liquidate_swap_weights: array![SCALE_128],
                    withdraw_swap: array![],
                    withdraw_swap_limit_amount: 0,
                    withdraw_swap_weights: array![]
                }
            );

        assert!(response.liquidated_collateral < collateral);
        assert!(response.repaid_debt == debt_);
        assert!(
            response.residual_collateral != 0
                && response.residual_collateral < usdc.balanceOf(liquidator)
        );
        assert!(eth.balanceOf(liquidate.contract_address) == 0);
        assert!(usdc.balanceOf(liquidate.contract_address) == 0);

        let (position, _, _) = singleton
            .position(pool_id, usdc.contract_address, eth.contract_address, user);
        assert!(position.nominal_debt == 0);
    }

    #[test]
    #[available_gas(20000000)]
    #[fork("Mainnet")]
    fn test_liquidate_position_full_liquidation_multi_split_swap_no_bad_debt() {
        let TestConfig { singleton, liquidate, pool_id, eth, usdc, user, .. } = setup();

        let params = ModifyPositionParams {
            pool_id,
            collateral_asset: usdc.contract_address,
            debt_asset: eth.contract_address,
            user: user,
            collateral: Amount {
                amount_type: AmountType::Delta,
                denomination: AmountDenomination::Assets,
                value: 14000_000_000.into()
            },
            debt: Amount {
                amount_type: AmountType::Delta,
                denomination: AmountDenomination::Assets,
                value: (3 * SCALE).into()
            },
            data: ArrayTrait::new().span()
        };

        start_prank(CheatTarget::One(usdc.contract_address), user);
        usdc.approve(singleton.contract_address, params.collateral.value.abs);
        stop_prank(CheatTarget::One(usdc.contract_address));

        start_prank(CheatTarget::One(singleton.contract_address), user);
        singleton.modify_position(params);
        stop_prank(CheatTarget::One(singleton.contract_address));

        let (_, collateral, debt) = singleton
            .position(pool_id, usdc.contract_address, eth.contract_address, user);
        assert!(collateral + 1 == params.collateral.value.abs);
        assert!(debt - 1 == params.debt.value.abs);

        let mock_pragma_oracle = IMockPragmaOracleDispatcher {
            contract_address: deploy_contract("MockPragmaOracle")
        };
        mock_pragma_oracle.set_num_sources_aggregated('USDC/USD', 10);
        mock_pragma_oracle.set_price('USDC/USD', SCALE_128 * 8 / 10);
        let extension = singleton.extension(pool_id);
        let price = IExtensionDispatcher { contract_address: extension }
            .price(pool_id, eth.contract_address);
        mock_pragma_oracle.set_num_sources_aggregated('ETH/USD', 10);
        mock_pragma_oracle.set_price('ETH/USD', price.value.try_into().unwrap());

        store(
            extension,
            selector!("oracle_address"),
            array![mock_pragma_oracle.contract_address.into()].span()
        );

        // reduce oracle price

        mock_pragma_oracle.set_price('USDC/USD', SCALE_128 * 8 / 10);

        let liquidator = contract_address_const::<'liquidator'>();

        assert!(usdc.balanceOf(liquidator) == 0);

        prank(CheatTarget::One(liquidate.contract_address), liquidator, CheatSpan::TargetCalls(1));

        let response: LiquidateResponse = liquidate
            .liquidate(
                LiquidateParams {
                    pool_id,
                    collateral_asset: usdc.contract_address,
                    debt_asset: eth.contract_address,
                    user,
                    recipient: liquidator,
                    min_collateral_to_receive: collateral / 2,
                    debt_to_repay: 0,
                    liquidate_swap: array![
                        Swap {
                            route: array![
                                RouteNode {
                                    pool_key: PoolKey {
                                        token0: contract_address_const::<
                                            0x49d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7
                                        >(),
                                        token1: contract_address_const::<
                                            0x53c91253bc9682c04929ca02ed00b3e423f6710d2ee7e0d5ebb06f3ecf368a8
                                        >(),
                                        fee: 0x20c49ba5e353f80000000000000000,
                                        tick_spacing: 1000,
                                        extension: contract_address_const::<0x0>()
                                    },
                                    sqrt_ratio_limit: MAX_SQRT_RATIO_LIMIT,
                                    skip_ahead: 0
                                }
                            ],
                            token_amount: TokenAmount {
                                token: eth.contract_address, amount: Zero::zero()
                            }
                        },
                        Swap {
                            route: array![
                                RouteNode {
                                    pool_key: PoolKey {
                                        token0: contract_address_const::<
                                            0x4718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d
                                        >(),
                                        token1: contract_address_const::<
                                            0x49d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7
                                        >(),
                                        fee: 0x68db8bac710cb4000000000000000,
                                        tick_spacing: 200,
                                        extension: contract_address_const::<0x0>()
                                    },
                                    sqrt_ratio_limit: MIN_SQRT_RATIO_LIMIT,
                                    skip_ahead: 0
                                },
                                RouteNode {
                                    pool_key: PoolKey {
                                        token0: contract_address_const::<
                                            0x4718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d
                                        >(),
                                        token1: contract_address_const::<
                                            0x53c91253bc9682c04929ca02ed00b3e423f6710d2ee7e0d5ebb06f3ecf368a8
                                        >(),
                                        fee: 0x20c49ba5e353f80000000000000000,
                                        tick_spacing: 1000,
                                        extension: contract_address_const::<0x0>()
                                    },
                                    sqrt_ratio_limit: MAX_SQRT_RATIO_LIMIT,
                                    skip_ahead: 0
                                }
                            ],
                            token_amount: TokenAmount {
                                token: eth.contract_address, amount: Zero::zero()
                            }
                        },
                        Swap {
                            route: array![
                                RouteNode {
                                    pool_key: PoolKey {
                                        token0: contract_address_const::<
                                            0x49d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7
                                        >(),
                                        token1: contract_address_const::<
                                            0x53c91253bc9682c04929ca02ed00b3e423f6710d2ee7e0d5ebb06f3ecf368a8
                                        >(),
                                        fee: 0x68db8bac710cb4000000000000000,
                                        tick_spacing: 200,
                                        extension: contract_address_const::<0x0>()
                                    },
                                    sqrt_ratio_limit: MAX_SQRT_RATIO_LIMIT,
                                    skip_ahead: 0
                                }
                            ],
                            token_amount: TokenAmount {
                                token: eth.contract_address, amount: Zero::zero()
                            }
                        },
                        Swap {
                            route: array![
                                RouteNode {
                                    pool_key: PoolKey {
                                        token0: contract_address_const::<
                                            0x49d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7
                                        >(),
                                        token1: contract_address_const::<
                                            0x68f5c6a61780768455de69077e07e89787839bf8166decfbf92b645209c0fb8
                                        >(),
                                        fee: 0x20c49ba5e353f80000000000000000,
                                        tick_spacing: 1000,
                                        extension: contract_address_const::<0x0>()
                                    },
                                    sqrt_ratio_limit: MAX_SQRT_RATIO_LIMIT,
                                    skip_ahead: 0
                                },
                                RouteNode {
                                    pool_key: PoolKey {
                                        token0: contract_address_const::<
                                            0x53c91253bc9682c04929ca02ed00b3e423f6710d2ee7e0d5ebb06f3ecf368a8
                                        >(),
                                        token1: contract_address_const::<
                                            0x68f5c6a61780768455de69077e07e89787839bf8166decfbf92b645209c0fb8
                                        >(),
                                        fee: 0x14f8b588e368f1000000000000000,
                                        tick_spacing: 20,
                                        extension: contract_address_const::<0x0>()
                                    },
                                    sqrt_ratio_limit: MIN_SQRT_RATIO_LIMIT,
                                    skip_ahead: 0
                                }
                            ],
                            token_amount: TokenAmount {
                                token: eth.contract_address, amount: Zero::zero()
                            }
                        },
                    ],
                    liquidate_swap_limit_amount: 12000_000_000,
                    liquidate_swap_weights: array![
                        SCALE_128 / 4, SCALE_128 / 4, SCALE_128 / 4, SCALE_128 / 4
                    ],
                    withdraw_swap: array![],
                    withdraw_swap_limit_amount: 0,
                    withdraw_swap_weights: array![]
                }
            );

        assert!(response.liquidated_collateral < collateral);
        assert!(response.repaid_debt == debt);
        assert!(
            response.residual_collateral != 0
                && response.residual_collateral == usdc.balanceOf(liquidator)
        );
        assert!(eth.balanceOf(liquidate.contract_address) == 0);
        assert!(usdc.balanceOf(liquidate.contract_address) == 0);

        let (position, _, _) = singleton
            .position(pool_id, usdc.contract_address, eth.contract_address, user);
        assert!(position.nominal_debt == 0);
    }

    #[test]
    #[available_gas(20000000)]
    #[should_panic(expected: "weight-sum-not-1")]
    #[fork("Mainnet")]
    fn test_liquidate_position_full_liquidation_multi_split_swap_no_bad_debt_weight_sum_not_1() {
        let TestConfig { singleton, liquidate, pool_id, eth, usdc, user, .. } = setup();

        let params = ModifyPositionParams {
            pool_id,
            collateral_asset: usdc.contract_address,
            debt_asset: eth.contract_address,
            user: user,
            collateral: Amount {
                amount_type: AmountType::Delta,
                denomination: AmountDenomination::Assets,
                value: 14000_000_000.into()
            },
            debt: Amount {
                amount_type: AmountType::Delta,
                denomination: AmountDenomination::Assets,
                value: (3 * SCALE).into()
            },
            data: ArrayTrait::new().span()
        };

        start_prank(CheatTarget::One(usdc.contract_address), user);
        usdc.approve(singleton.contract_address, params.collateral.value.abs);
        stop_prank(CheatTarget::One(usdc.contract_address));

        start_prank(CheatTarget::One(singleton.contract_address), user);
        singleton.modify_position(params);
        stop_prank(CheatTarget::One(singleton.contract_address));

        let (_, collateral, debt) = singleton
            .position(pool_id, usdc.contract_address, eth.contract_address, user);
        assert!(collateral + 1 == params.collateral.value.abs);
        assert!(debt - 1 == params.debt.value.abs);

        let mock_pragma_oracle = IMockPragmaOracleDispatcher {
            contract_address: deploy_contract("MockPragmaOracle")
        };
        mock_pragma_oracle.set_num_sources_aggregated('USDC/USD', 10);
        mock_pragma_oracle.set_price('USDC/USD', SCALE_128 * 8 / 10);
        let extension = singleton.extension(pool_id);
        let price = IExtensionDispatcher { contract_address: extension }
            .price(pool_id, eth.contract_address);
        mock_pragma_oracle.set_num_sources_aggregated('ETH/USD', 10);
        mock_pragma_oracle.set_price('ETH/USD', price.value.try_into().unwrap());

        store(
            extension,
            selector!("oracle_address"),
            array![mock_pragma_oracle.contract_address.into()].span()
        );

        // reduce oracle price

        mock_pragma_oracle.set_price('USDC/USD', SCALE_128 * 8 / 10);

        let liquidator = contract_address_const::<'liquidator'>();

        assert!(usdc.balanceOf(liquidator) == 0);

        prank(CheatTarget::One(liquidate.contract_address), liquidator, CheatSpan::TargetCalls(1));

        liquidate
            .liquidate(
                LiquidateParams {
                    pool_id,
                    collateral_asset: usdc.contract_address,
                    debt_asset: eth.contract_address,
                    user,
                    recipient: liquidator,
                    min_collateral_to_receive: collateral / 2,
                    debt_to_repay: 0,
                    liquidate_swap: array![
                        Swap {
                            route: array![
                                RouteNode {
                                    pool_key: PoolKey {
                                        token0: contract_address_const::<
                                            0x49d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7
                                        >(),
                                        token1: contract_address_const::<
                                            0x53c91253bc9682c04929ca02ed00b3e423f6710d2ee7e0d5ebb06f3ecf368a8
                                        >(),
                                        fee: 0x20c49ba5e353f80000000000000000,
                                        tick_spacing: 1000,
                                        extension: contract_address_const::<0x0>()
                                    },
                                    sqrt_ratio_limit: MAX_SQRT_RATIO_LIMIT,
                                    skip_ahead: 0
                                }
                            ],
                            token_amount: TokenAmount {
                                token: eth.contract_address, amount: Zero::zero()
                            }
                        },
                        Swap {
                            route: array![
                                RouteNode {
                                    pool_key: PoolKey {
                                        token0: contract_address_const::<
                                            0x4718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d
                                        >(),
                                        token1: contract_address_const::<
                                            0x49d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7
                                        >(),
                                        fee: 0x68db8bac710cb4000000000000000,
                                        tick_spacing: 200,
                                        extension: contract_address_const::<0x0>()
                                    },
                                    sqrt_ratio_limit: MIN_SQRT_RATIO_LIMIT,
                                    skip_ahead: 0
                                },
                                RouteNode {
                                    pool_key: PoolKey {
                                        token0: contract_address_const::<
                                            0x4718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d
                                        >(),
                                        token1: contract_address_const::<
                                            0x53c91253bc9682c04929ca02ed00b3e423f6710d2ee7e0d5ebb06f3ecf368a8
                                        >(),
                                        fee: 0x20c49ba5e353f80000000000000000,
                                        tick_spacing: 1000,
                                        extension: contract_address_const::<0x0>()
                                    },
                                    sqrt_ratio_limit: MAX_SQRT_RATIO_LIMIT,
                                    skip_ahead: 0
                                }
                            ],
                            token_amount: TokenAmount {
                                token: eth.contract_address, amount: Zero::zero()
                            }
                        },
                        Swap {
                            route: array![
                                RouteNode {
                                    pool_key: PoolKey {
                                        token0: contract_address_const::<
                                            0x49d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7
                                        >(),
                                        token1: contract_address_const::<
                                            0x53c91253bc9682c04929ca02ed00b3e423f6710d2ee7e0d5ebb06f3ecf368a8
                                        >(),
                                        fee: 0x68db8bac710cb4000000000000000,
                                        tick_spacing: 200,
                                        extension: contract_address_const::<0x0>()
                                    },
                                    sqrt_ratio_limit: MAX_SQRT_RATIO_LIMIT,
                                    skip_ahead: 0
                                }
                            ],
                            token_amount: TokenAmount {
                                token: eth.contract_address, amount: Zero::zero()
                            }
                        },
                        Swap {
                            route: array![
                                RouteNode {
                                    pool_key: PoolKey {
                                        token0: contract_address_const::<
                                            0x49d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7
                                        >(),
                                        token1: contract_address_const::<
                                            0x68f5c6a61780768455de69077e07e89787839bf8166decfbf92b645209c0fb8
                                        >(),
                                        fee: 0x20c49ba5e353f80000000000000000,
                                        tick_spacing: 1000,
                                        extension: contract_address_const::<0x0>()
                                    },
                                    sqrt_ratio_limit: MAX_SQRT_RATIO_LIMIT,
                                    skip_ahead: 0
                                },
                                RouteNode {
                                    pool_key: PoolKey {
                                        token0: contract_address_const::<
                                            0x53c91253bc9682c04929ca02ed00b3e423f6710d2ee7e0d5ebb06f3ecf368a8
                                        >(),
                                        token1: contract_address_const::<
                                            0x68f5c6a61780768455de69077e07e89787839bf8166decfbf92b645209c0fb8
                                        >(),
                                        fee: 0x14f8b588e368f1000000000000000,
                                        tick_spacing: 20,
                                        extension: contract_address_const::<0x0>()
                                    },
                                    sqrt_ratio_limit: MIN_SQRT_RATIO_LIMIT,
                                    skip_ahead: 0
                                }
                            ],
                            token_amount: TokenAmount {
                                token: eth.contract_address, amount: Zero::zero()
                            }
                        },
                    ],
                    liquidate_swap_limit_amount: 12000_000_000,
                    liquidate_swap_weights: array![
                        SCALE_128 / 2, SCALE_128 / 4, SCALE_128 / 4, SCALE_128 / 4
                    ],
                    withdraw_swap: array![],
                    withdraw_swap_limit_amount: 0,
                    withdraw_swap_weights: array![]
                }
            );
    }
}
