use starknet::{ContractAddress};

#[starknet::interface]
trait IStarkgateERC20<TContractState> {
    fn permissioned_mint(ref self: TContractState, account: ContractAddress, amount: u256);
}

#[cfg(test)]
mod Test_896150_Multiply {
    use snforge_std::{start_prank, stop_prank, start_warp, stop_warp, CheatTarget, load};
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
        singleton::{ISingletonDispatcher, ISingletonDispatcherTrait}, test::setup::deploy_with_args,
        common::{i257, i257_new}
    };
    use vesu_periphery::multiply::{
        IMultiplyDispatcher, IMultiplyDispatcherTrait, ModifyLeverParams, IncreaseLeverParams,
        DecreaseLeverParams, ModifyLeverAction
    };
    use vesu_periphery::swap::{RouteNode, TokenAmount, Swap};

    use super::{IStarkgateERC20Dispatcher, IStarkgateERC20DispatcherTrait};

    const MIN_SQRT_RATIO_LIMIT: u256 = 18446748437148339061;
    const MAX_SQRT_RATIO_LIMIT: u256 = 6277100250585753475930931601400621808602321654880405518632;

    struct TestConfig {
        ekubo: ICoreDispatcher,
        singleton: ISingletonDispatcher,
        multiply: IMultiplyDispatcher,
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
        let multiply = IMultiplyDispatcher {
            contract_address: deploy_with_args(
                "Multiply", array![ekubo.contract_address.into(), singleton.contract_address.into()]
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
            .permissioned_mint(user, 10000_000_000);
        stop_prank(CheatTarget::One(usdc.contract_address));

        let loaded = load(usdt.contract_address, selector!("permitted_minter"), 1);
        let minter: ContractAddress = (*loaded[0]).try_into().unwrap();
        start_prank(CheatTarget::One(usdt.contract_address), minter);
        IStarkgateERC20Dispatcher { contract_address: usdt.contract_address }
            .permissioned_mint(user, 10010_000_000);
        stop_prank(CheatTarget::One(usdt.contract_address));

        let test_config = TestConfig {
            ekubo,
            singleton,
            multiply,
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
    fn test_modify_lever_no_lever_swap() {
        let TestConfig { singleton, multiply, pool_id, eth, usdc, user, .. } = setup();

        let usdc_balance_before = usdc.balanceOf(user);

        usdc.approve(multiply.contract_address, 10000_000_000.into());
        singleton.modify_delegation(pool_id, multiply.contract_address, true);

        let increase_lever_params = IncreaseLeverParams {
            pool_id,
            collateral_asset: usdc.contract_address,
            debt_asset: eth.contract_address,
            user,
            add_margin: 10000_000_000_u128,
            margin_swap: array![],
            margin_swap_limit_amount: 0,
            lever_swap: array![],
            lever_swap_limit_amount: 0,
        };

        let modify_lever_params = ModifyLeverParams {
            action: ModifyLeverAction::IncreaseLever(increase_lever_params.clone())
        };

        multiply.modify_lever(modify_lever_params);

        let (_, collateral, _) = singleton
            .position(pool_id, usdc.contract_address, eth.contract_address, user);

        assert!(collateral + 1 == increase_lever_params.add_margin.into());
        assert!(
            usdc.balanceOf(user) == usdc_balance_before - increase_lever_params.add_margin.into()
        );
    }

    #[test]
    #[available_gas(20000000)]
    #[fork("Mainnet")]
    fn test_modify_lever_exact_collateral_deposit() {
        let TestConfig { singleton, multiply, pool_id, pool_key, eth, usdc, user, .. } = setup();

        let usdc_balance_before = usdc.balanceOf(user);

        usdc.approve(multiply.contract_address, 10000_000_000.into());
        singleton.modify_delegation(pool_id, multiply.contract_address, true);

        let increase_lever_params = IncreaseLeverParams {
            pool_id,
            collateral_asset: usdc.contract_address,
            debt_asset: eth.contract_address,
            user,
            add_margin: 10000_000_000_u128,
            margin_swap: array![],
            margin_swap_limit_amount: 0,
            lever_swap: array![
                Swap {
                    route: array![
                        RouteNode {
                            pool_key, sqrt_ratio_limit: MIN_SQRT_RATIO_LIMIT, skip_ahead: 0
                        }
                    ],
                    token_amount: TokenAmount {
                        token: usdc.contract_address,
                        amount: i129_new((110_000_000).try_into().unwrap(), true)
                    }
                }
            ],
            lever_swap_limit_amount: 44000000000000000, // 0.044 ETH
        };

        let modify_lever_params = ModifyLeverParams {
            action: ModifyLeverAction::IncreaseLever(increase_lever_params.clone())
        };

        multiply.modify_lever(modify_lever_params);

        let (_, collateral, _) = singleton
            .position(pool_id, usdc.contract_address, eth.contract_address, user);

        let y: @Swap = (increase_lever_params.lever_swap[0]);
        let x: u256 = (*y.token_amount.amount.mag).into();
        assert!(collateral + 1 == increase_lever_params.add_margin.into() + x);

        assert!(
            usdc.balanceOf(user) == usdc_balance_before - increase_lever_params.add_margin.into()
        );
    }

    #[test]
    #[available_gas(20000000)]
    #[fork("Mainnet")]
    fn test_modify_lever_exact_debt_borrow() {
        let TestConfig { singleton, multiply, pool_id, pool_key, eth, usdc, user, .. } = setup();

        let usdc_balance_before = usdc.balanceOf(user);

        usdc.approve(multiply.contract_address, 10000_000_000.into());
        singleton.modify_delegation(pool_id, multiply.contract_address, true);

        let increase_lever_params = IncreaseLeverParams {
            pool_id,
            collateral_asset: usdc.contract_address,
            debt_asset: eth.contract_address,
            user,
            add_margin: 10000_000_000_u128,
            margin_swap: array![],
            margin_swap_limit_amount: 0,
            lever_swap: array![
                Swap {
                    route: array![
                        RouteNode {
                            pool_key, sqrt_ratio_limit: MIN_SQRT_RATIO_LIMIT, skip_ahead: 0
                        }
                    ],
                    token_amount: TokenAmount {
                        token: eth.contract_address,
                        amount: i129_new((44000000000000000).try_into().unwrap(), false),
                    }
                }
            ],
            lever_swap_limit_amount: 0,
        };

        let modify_lever_params = ModifyLeverParams {
            action: ModifyLeverAction::IncreaseLever(increase_lever_params.clone())
        };

        multiply.modify_lever(modify_lever_params);

        let (_, _, debt) = singleton
            .position(pool_id, usdc.contract_address, eth.contract_address, user);

        let y: @Swap = (increase_lever_params.lever_swap[0]);
        let x: u256 = (*y.token_amount.amount.mag).into();
        assert!(debt - 1 == x);

        assert!(
            usdc.balanceOf(user) == usdc_balance_before - increase_lever_params.add_margin.into()
        );
    }

    #[test]
    #[available_gas(20000000)]
    #[fork("Mainnet")]
    fn test_modify_lever_margin_asset_swap_exact_out() {
        let TestConfig { singleton,
        multiply,
        pool_id,
        pool_key,
        pool_key_2,
        eth,
        usdc,
        usdt,
        user,
        .. } =
            setup();

        let usdt_balance_before = usdt.balanceOf(user);

        usdt.approve(multiply.contract_address, 10010_000_000.into());
        singleton.modify_delegation(pool_id, multiply.contract_address, true);

        let increase_lever_params = IncreaseLeverParams {
            pool_id,
            collateral_asset: usdc.contract_address,
            debt_asset: eth.contract_address,
            user,
            add_margin: 0_u128,
            margin_swap: array![
                Swap {
                    route: array![
                        RouteNode {
                            pool_key: pool_key_2,
                            sqrt_ratio_limit: MAX_SQRT_RATIO_LIMIT,
                            skip_ahead: 0
                        }
                    ],
                    token_amount: TokenAmount {
                        token: usdc.contract_address,
                        amount: i129_new((10000_000_000).try_into().unwrap(), true)
                    },
                }
            ],
            margin_swap_limit_amount: (10010_000_000).try_into().unwrap(),
            lever_swap: array![
                Swap {
                    route: array![
                        RouteNode {
                            pool_key, sqrt_ratio_limit: MIN_SQRT_RATIO_LIMIT, skip_ahead: 0
                        }
                    ],
                    token_amount: TokenAmount {
                        token: usdc.contract_address,
                        amount: i129_new((110_000_000).try_into().unwrap(), true)
                    },
                }
            ],
            lever_swap_limit_amount: 44000000000000000, // 0.044 ETH
        };

        let modify_lever_params = ModifyLeverParams {
            action: ModifyLeverAction::IncreaseLever(increase_lever_params.clone())
        };

        multiply.modify_lever(modify_lever_params);

        let (_, collateral, _) = singleton
            .position(pool_id, usdc.contract_address, eth.contract_address, user);

        let margin_swap: @Swap = (increase_lever_params.margin_swap[0]);
        let margin_swap_amount: u256 = (*margin_swap.token_amount.amount.mag).into();
        let lever_swap: @Swap = (increase_lever_params.lever_swap[0]);
        let lever_swap_amount: u256 = (*lever_swap.token_amount.amount.mag).into();
        assert!(collateral + 1 == margin_swap_amount + lever_swap_amount);

        assert!(usdt.balanceOf(user) < usdt_balance_before);
        assert!(usdt.balanceOf(user) != 0);
    }

    #[test]
    #[available_gas(20000000)]
    #[fork("Mainnet")]
    fn test_modify_lever_margin_asset_swap_exact_in() {
        let TestConfig { singleton,
        multiply,
        pool_id,
        pool_key,
        pool_key_2,
        eth,
        usdc,
        usdt,
        user,
        .. } =
            setup();

        let usdt_balance_before = usdt.balanceOf(user);

        usdt.approve(multiply.contract_address, 10010_000_000.into());
        singleton.modify_delegation(pool_id, multiply.contract_address, true);

        let increase_lever_params = IncreaseLeverParams {
            pool_id,
            collateral_asset: usdc.contract_address,
            debt_asset: eth.contract_address,
            user,
            add_margin: 0_u128,
            margin_swap: array![
                Swap {
                    route: array![
                        RouteNode {
                            pool_key: pool_key_2,
                            sqrt_ratio_limit: MAX_SQRT_RATIO_LIMIT,
                            skip_ahead: 0
                        }
                    ],
                    token_amount: TokenAmount {
                        token: usdt.contract_address,
                        amount: i129_new((10010_000_000).try_into().unwrap(), false)
                    },
                }
            ],
            margin_swap_limit_amount: Zero::zero(),
            lever_swap: array![
                Swap {
                    route: array![
                        RouteNode {
                            pool_key, sqrt_ratio_limit: MIN_SQRT_RATIO_LIMIT, skip_ahead: 0
                        }
                    ],
                    token_amount: TokenAmount {
                        token: usdc.contract_address,
                        amount: i129_new((110_000_000).try_into().unwrap(), true)
                    },
                }
            ],
            lever_swap_limit_amount: 44000000000000000, // 0.044 ETH
        };

        let modify_lever_params = ModifyLeverParams {
            action: ModifyLeverAction::IncreaseLever(increase_lever_params.clone())
        };

        multiply.modify_lever(modify_lever_params);

        let (_, collateral, _) = singleton
            .position(pool_id, usdc.contract_address, eth.contract_address, user);

        let margin_swap: @Swap = (increase_lever_params.margin_swap[0]);
        let margin_swap_amount: u256 = (*margin_swap.token_amount.amount.mag).into();
        let lever_swap: @Swap = (increase_lever_params.lever_swap[0]);
        let lever_swap_amount: u256 = (*lever_swap.token_amount.amount.mag).into();
        assert!(
            collateral == (margin_swap_amount + lever_swap_amount)
                + 10997782 // positive swap slippage
        );

        assert!(usdt.balanceOf(user) < usdt_balance_before);
        assert!(usdt.balanceOf(user) == 0);
    }

    #[test]
    #[available_gas(20000000)]
    #[fork("Mainnet")]
    fn test_modify_lever_exact_collateral_withdrawal() {
        let TestConfig { singleton, multiply, pool_id, pool_key, eth, usdc, user, .. } = setup();

        usdc.approve(multiply.contract_address, 10000_000_000.into());
        singleton.modify_delegation(pool_id, multiply.contract_address, true);

        let increase_lever_params = IncreaseLeverParams {
            pool_id,
            collateral_asset: usdc.contract_address,
            debt_asset: eth.contract_address,
            user,
            add_margin: 10000_000_000_u128,
            margin_swap: array![],
            margin_swap_limit_amount: 0,
            lever_swap: array![
                Swap {
                    route: array![
                        RouteNode {
                            pool_key, sqrt_ratio_limit: MIN_SQRT_RATIO_LIMIT, skip_ahead: 0
                        }
                    ],
                    token_amount: TokenAmount {
                        token: usdc.contract_address,
                        amount: i129_new((300_000_000).try_into().unwrap(), true)
                    }
                }
            ],
            lever_swap_limit_amount: 120000000000000000, // 0.12 ETH
        };

        let modify_lever_params = ModifyLeverParams {
            action: ModifyLeverAction::IncreaseLever(increase_lever_params.clone())
        };

        multiply.modify_lever(modify_lever_params);

        let (_, collateral_amount, _) = singleton
            .position(pool_id, usdc.contract_address, eth.contract_address, user);

        let usdc_balance_before = usdc.balanceOf(user);

        let decrease_lever_params = DecreaseLeverParams {
            pool_id,
            collateral_asset: usdc.contract_address,
            debt_asset: eth.contract_address,
            user,
            sub_margin: 0,
            recipient: user,
            lever_swap: array![
                Swap {
                    route: array![
                        RouteNode {
                            pool_key, sqrt_ratio_limit: MAX_SQRT_RATIO_LIMIT, skip_ahead: 0
                        }
                    ],
                    token_amount: TokenAmount {
                        token: usdc.contract_address,
                        amount: i129_new((collateral_amount / 200).try_into().unwrap(), false)
                    },
                }
            ],
            lever_swap_limit_amount: 0,
            lever_swap_weights: array![],
            withdraw_swap: array![],
            withdraw_swap_limit_amount: 0,
            withdraw_swap_weights: array![],
            close_position: false
        };

        let modify_lever_params = ModifyLeverParams {
            action: ModifyLeverAction::DecreaseLever(decrease_lever_params.clone())
        };

        multiply.modify_lever(modify_lever_params);

        let (_, collateral, _) = singleton
            .position(pool_id, usdc.contract_address, eth.contract_address, user);

        let lever_swap: @Swap = (decrease_lever_params.lever_swap[0]);
        let lever_swap_amount: u256 = (*lever_swap.token_amount.amount.mag).into();
        assert!(collateral == collateral_amount - lever_swap_amount);

        assert!(usdc.balanceOf(user) == usdc_balance_before);
    }

    #[test]
    #[available_gas(20000000)]
    #[fork("Mainnet")]
    fn test_modify_lever_exact_collateral_withdrawal_no_lever_swap() {
        let TestConfig { singleton, multiply, pool_id, pool_key, eth, usdc, user, .. } = setup();

        usdc.approve(multiply.contract_address, 10000_000_000.into());
        singleton.modify_delegation(pool_id, multiply.contract_address, true);

        let increase_lever_params = IncreaseLeverParams {
            pool_id,
            collateral_asset: usdc.contract_address,
            debt_asset: eth.contract_address,
            user,
            add_margin: 10000_000_000_u128,
            margin_swap: array![],
            margin_swap_limit_amount: 0,
            lever_swap: array![
                Swap {
                    route: array![
                        RouteNode {
                            pool_key, sqrt_ratio_limit: MIN_SQRT_RATIO_LIMIT, skip_ahead: 0
                        }
                    ],
                    token_amount: TokenAmount {
                        token: usdc.contract_address,
                        amount: i129_new((300_000_000).try_into().unwrap(), true)
                    },
                }
            ],
            lever_swap_limit_amount: 120000000000000000, // 0.12 ETH
        };

        let modify_lever_params = ModifyLeverParams {
            action: ModifyLeverAction::IncreaseLever(increase_lever_params.clone())
        };

        multiply.modify_lever(modify_lever_params);

        let (_, collateral_amount, _) = singleton
            .position(pool_id, usdc.contract_address, eth.contract_address, user);

        let usdc_balance_before = usdc.balanceOf(user);

        let decrease_lever_params = DecreaseLeverParams {
            pool_id,
            collateral_asset: usdc.contract_address,
            debt_asset: eth.contract_address,
            user,
            sub_margin: 1000_000_000_u128,
            recipient: user,
            lever_swap: array![],
            lever_swap_limit_amount: 0,
            lever_swap_weights: array![],
            withdraw_swap: array![],
            withdraw_swap_limit_amount: 0,
            withdraw_swap_weights: array![],
            close_position: false
        };

        let modify_lever_params = ModifyLeverParams {
            action: ModifyLeverAction::DecreaseLever(decrease_lever_params.clone())
        };

        multiply.modify_lever(modify_lever_params);

        let (_, collateral, _) = singleton
            .position(pool_id, usdc.contract_address, eth.contract_address, user);

        assert!(collateral == collateral_amount - decrease_lever_params.sub_margin.into());
        assert!(usdc.balanceOf(user) > usdc_balance_before);
    }

    #[test]
    #[available_gas(20000000)]
    #[fork("Mainnet")]
    fn test_modify_lever_exact_debt_repay() {
        let TestConfig { singleton, multiply, pool_id, pool_key, eth, usdc, user, .. } = setup();

        usdc.approve(multiply.contract_address, 10000_000_000.into());
        singleton.modify_delegation(pool_id, multiply.contract_address, true);

        let increase_lever_params = IncreaseLeverParams {
            pool_id,
            collateral_asset: usdc.contract_address,
            debt_asset: eth.contract_address,
            user,
            add_margin: 10000_000_000_u128,
            margin_swap: array![],
            margin_swap_limit_amount: 0,
            lever_swap: array![
                Swap {
                    route: array![
                        RouteNode {
                            pool_key, sqrt_ratio_limit: MIN_SQRT_RATIO_LIMIT, skip_ahead: 0
                        }
                    ],
                    token_amount: TokenAmount {
                        token: usdc.contract_address,
                        amount: i129_new((110_000_000).try_into().unwrap(), true)
                    }
                }
            ],
            lever_swap_limit_amount: 44000000000000000, // 0.044 ETH
        };

        let modify_lever_params = ModifyLeverParams {
            action: ModifyLeverAction::IncreaseLever(increase_lever_params.clone())
        };

        multiply.modify_lever(modify_lever_params);

        let usdc_balance_before = usdc.balanceOf(user);

        let (_, _, debt_amount) = singleton
            .position(pool_id, usdc.contract_address, eth.contract_address, user);

        let decrease_lever_params = DecreaseLeverParams {
            pool_id,
            collateral_asset: usdc.contract_address,
            debt_asset: eth.contract_address,
            user,
            sub_margin: 9999_000_000_u128,
            recipient: user,
            lever_swap: array![
                Swap {
                    route: array![
                        RouteNode {
                            pool_key, sqrt_ratio_limit: MAX_SQRT_RATIO_LIMIT, skip_ahead: 0
                        }
                    ],
                    token_amount: TokenAmount {
                        token: eth.contract_address,
                        amount: i129_new(debt_amount.try_into().unwrap(), true)
                    }
                }
            ],
            lever_swap_limit_amount: 121_000_000_u128,
            lever_swap_weights: array![],
            withdraw_swap: array![],
            withdraw_swap_limit_amount: 0,
            withdraw_swap_weights: array![],
            close_position: false,
        };

        let modify_lever_params = ModifyLeverParams {
            action: ModifyLeverAction::DecreaseLever(decrease_lever_params.clone())
        };

        multiply.modify_lever(modify_lever_params);

        let (_, _, debt) = singleton
            .position(pool_id, usdc.contract_address, eth.contract_address, user);

        let lever_swap: @Swap = (decrease_lever_params.lever_swap[0]);
        let lever_swap_amount: u256 = (*lever_swap.token_amount.amount.mag).into();
        assert!(debt == debt_amount - lever_swap_amount);

        assert!(
            usdc.balanceOf(user) == usdc_balance_before + decrease_lever_params.sub_margin.into()
        );
    }

    #[test]
    #[available_gas(20000000)]
    #[fork("Mainnet")]
    fn test_modify_lever_withdraw_swap_exact_in() {
        let TestConfig { singleton,
        multiply,
        pool_id,
        pool_key,
        pool_key_2,
        eth,
        usdc,
        usdt,
        user,
        .. } =
            setup();

        usdc.approve(multiply.contract_address, 10000_000_000.into());
        singleton.modify_delegation(pool_id, multiply.contract_address, true);

        let increase_lever_params = IncreaseLeverParams {
            pool_id,
            collateral_asset: usdc.contract_address,
            debt_asset: eth.contract_address,
            user,
            add_margin: 10000_000_000_u128,
            margin_swap: array![],
            margin_swap_limit_amount: 0,
            lever_swap: array![
                Swap {
                    route: array![
                        RouteNode {
                            pool_key, sqrt_ratio_limit: MIN_SQRT_RATIO_LIMIT, skip_ahead: 0
                        }
                    ],
                    token_amount: TokenAmount {
                        token: usdc.contract_address,
                        amount: i129_new((300_000_000).try_into().unwrap(), true)
                    },
                }
            ],
            lever_swap_limit_amount: 120000000000000000, // 0.12 ETH
        };

        let modify_lever_params = ModifyLeverParams {
            action: ModifyLeverAction::IncreaseLever(increase_lever_params.clone())
        };

        multiply.modify_lever(modify_lever_params);

        let (_, collateral_amount, _) = singleton
            .position(pool_id, usdc.contract_address, eth.contract_address, user);

        let usdc_balance_before = usdc.balanceOf(user);
        let usdt_balance_before = usdt.balanceOf(user);

        let decrease_lever_params = DecreaseLeverParams {
            pool_id,
            collateral_asset: usdc.contract_address,
            debt_asset: eth.contract_address,
            user,
            sub_margin: 0_u128,
            recipient: user,
            lever_swap: array![
                Swap {
                    route: array![
                        RouteNode {
                            pool_key, sqrt_ratio_limit: MAX_SQRT_RATIO_LIMIT, skip_ahead: 0
                        }
                    ],
                    token_amount: TokenAmount {
                        token: usdc.contract_address,
                        amount: i129_new((collateral_amount / 200).try_into().unwrap(), false)
                    },
                }
            ],
            lever_swap_limit_amount: 0,
            lever_swap_weights: array![],
            withdraw_swap: array![
                Swap {
                    route: array![
                        RouteNode {
                            pool_key: pool_key_2,
                            sqrt_ratio_limit: MIN_SQRT_RATIO_LIMIT,
                            skip_ahead: 0
                        }
                    ],
                    token_amount: TokenAmount {
                        token: usdc.contract_address, amount: Zero::zero(),
                    },
                }
            ],
            withdraw_swap_limit_amount: 0,
            withdraw_swap_weights: array![SCALE_128],
            close_position: false,
        };

        let modify_lever_params = ModifyLeverParams {
            action: ModifyLeverAction::DecreaseLever(decrease_lever_params.clone())
        };

        multiply.modify_lever(modify_lever_params);

        let (_, collateral, _) = singleton
            .position(pool_id, usdc.contract_address, eth.contract_address, user);

        let lever_swap: @Swap = (decrease_lever_params.lever_swap[0]);
        let lever_swap_amount: u256 = (*lever_swap.token_amount.amount.mag).into();
        assert!(collateral == collateral_amount - lever_swap_amount);

        assert!(usdc.balanceOf(user) == usdc_balance_before);
        assert!(usdt.balanceOf(user) >= usdt_balance_before);
        assert!(
            usdt.balanceOf(user) <= usdt_balance_before + decrease_lever_params.sub_margin.into()
        );
    }

    #[test]
    #[available_gas(20000000)]
    #[should_panic(expected: "weight-sum-not-1")]
    #[fork("Mainnet")]
    fn test_modify_lever_close_weight_sum_not_1() {
        let TestConfig { singleton, multiply, pool_id, pool_key, eth, usdc, user, .. } = setup();

        usdc.approve(multiply.contract_address, 10000_000_000.into());
        singleton.modify_delegation(pool_id, multiply.contract_address, true);

        let increase_lever_params = IncreaseLeverParams {
            pool_id,
            collateral_asset: usdc.contract_address,
            debt_asset: eth.contract_address,
            user,
            add_margin: 10000_000_000_u128,
            margin_swap: array![],
            margin_swap_limit_amount: 0,
            lever_swap: array![
                Swap {
                    route: array![
                        RouteNode {
                            pool_key, sqrt_ratio_limit: MIN_SQRT_RATIO_LIMIT, skip_ahead: 0
                        }
                    ],
                    token_amount: TokenAmount {
                        token: usdc.contract_address,
                        amount: i129_new((110_000_000).try_into().unwrap(), true)
                    },
                }
            ],
            lever_swap_limit_amount: 44000000000000000, // 0.044 ETH
        };

        let modify_lever_params = ModifyLeverParams {
            action: ModifyLeverAction::IncreaseLever(increase_lever_params.clone())
        };

        multiply.modify_lever(modify_lever_params);

        let decrease_lever_params = DecreaseLeverParams {
            pool_id,
            collateral_asset: usdc.contract_address,
            debt_asset: eth.contract_address,
            user,
            sub_margin: 0,
            recipient: user,
            lever_swap: array![
                Swap {
                    route: array![
                        RouteNode {
                            pool_key, sqrt_ratio_limit: MAX_SQRT_RATIO_LIMIT, skip_ahead: 0
                        }
                    ],
                    token_amount: TokenAmount {
                        token: eth.contract_address, amount: Zero::zero(),
                    },
                }
            ],
            lever_swap_limit_amount: 121_000_000_u128,
            lever_swap_weights: array![SCALE_128 * 2],
            withdraw_swap: array![],
            withdraw_swap_limit_amount: 0,
            withdraw_swap_weights: array![],
            close_position: true
        };

        let modify_lever_params = ModifyLeverParams {
            action: ModifyLeverAction::DecreaseLever(decrease_lever_params.clone())
        };

        multiply.modify_lever(modify_lever_params);
    }

    #[test]
    #[available_gas(20000000)]
    #[fork("Mainnet")]
    fn test_modify_lever_close() {
        let TestConfig { singleton, multiply, pool_id, pool_key, eth, usdc, user, .. } = setup();

        usdc.approve(multiply.contract_address, 10000_000_000.into());
        singleton.modify_delegation(pool_id, multiply.contract_address, true);

        let increase_lever_params = IncreaseLeverParams {
            pool_id,
            collateral_asset: usdc.contract_address,
            debt_asset: eth.contract_address,
            user,
            add_margin: 10000_000_000_u128,
            margin_swap: array![],
            margin_swap_limit_amount: 0,
            lever_swap: array![
                Swap {
                    route: array![
                        RouteNode {
                            pool_key, sqrt_ratio_limit: MIN_SQRT_RATIO_LIMIT, skip_ahead: 0
                        }
                    ],
                    token_amount: TokenAmount {
                        token: usdc.contract_address,
                        amount: i129_new((110_000_000).try_into().unwrap(), true)
                    },
                }
            ],
            lever_swap_limit_amount: 44000000000000000, // 0.044 ETH
        };

        let modify_lever_params = ModifyLeverParams {
            action: ModifyLeverAction::IncreaseLever(increase_lever_params.clone())
        };

        multiply.modify_lever(modify_lever_params);

        let user_balance_before = usdc.balanceOf(user);

        let decrease_lever_params = DecreaseLeverParams {
            pool_id,
            collateral_asset: usdc.contract_address,
            debt_asset: eth.contract_address,
            user,
            sub_margin: 0,
            recipient: user,
            lever_swap: array![
                Swap {
                    route: array![
                        RouteNode {
                            pool_key, sqrt_ratio_limit: MAX_SQRT_RATIO_LIMIT, skip_ahead: 0
                        }
                    ],
                    token_amount: TokenAmount {
                        token: eth.contract_address, amount: Zero::zero(),
                    },
                }
            ],
            lever_swap_limit_amount: 121_000_000_u128,
            lever_swap_weights: array![SCALE_128],
            withdraw_swap: array![],
            withdraw_swap_limit_amount: 0,
            withdraw_swap_weights: array![],
            close_position: true
        };

        let modify_lever_params = ModifyLeverParams {
            action: ModifyLeverAction::DecreaseLever(decrease_lever_params.clone())
        };

        let (_, collateral, debt) = singleton
            .position(pool_id, usdc.contract_address, eth.contract_address, user);

        let modify_lever_response = multiply.modify_lever(modify_lever_params);

        assert!(modify_lever_response.collateral_delta == i257_new(collateral, true));
        assert!(modify_lever_response.debt_delta == i257_new(debt, true));
        assert!(modify_lever_response.margin_delta <= i257_new(9999_000_000, true));

        let (position, collateral, debt) = singleton
            .position(pool_id, usdc.contract_address, eth.contract_address, user);
        assert!(position.collateral_shares == 0);
        assert!(position.nominal_debt == 0);
        assert!(collateral == 0);
        assert!(debt == 0);

        assert!(
            usdc.balanceOf(user) >= user_balance_before + decrease_lever_params.sub_margin.into()
        );
    }

    #[test]
    #[available_gas(20000000)]
    #[fork("Mainnet")]
    fn test_modify_lever_multi_swap() {
        let TestConfig { singleton,
        multiply,
        pool_id,
        pool_key_3,
        pool_key_4,
        eth,
        usdc,
        user,
        .. } =
            setup();

        let usdc_balance_before = usdc.balanceOf(user);

        usdc.approve(multiply.contract_address, 10000_000_000.into());
        singleton.modify_delegation(pool_id, multiply.contract_address, true);

        let increase_lever_params = IncreaseLeverParams {
            pool_id,
            collateral_asset: usdc.contract_address,
            debt_asset: eth.contract_address,
            user,
            add_margin: 10000_000_000_u128,
            margin_swap: array![],
            margin_swap_limit_amount: 0,
            lever_swap: array![
                Swap {
                    route: array![
                        RouteNode {
                            pool_key: pool_key_3,
                            sqrt_ratio_limit: MIN_SQRT_RATIO_LIMIT,
                            skip_ahead: 0
                        },
                        RouteNode {
                            pool_key: pool_key_4,
                            sqrt_ratio_limit: MAX_SQRT_RATIO_LIMIT,
                            skip_ahead: 0
                        }
                    ],
                    token_amount: TokenAmount {
                        token: usdc.contract_address,
                        amount: i129_new((110_000_000).try_into().unwrap(), true)
                    },
                }
            ],
            lever_swap_limit_amount: 44000000000000000, // 0.044 ETH
        };

        let modify_lever_params = ModifyLeverParams {
            action: ModifyLeverAction::IncreaseLever(increase_lever_params.clone())
        };

        let modify_lever_response = multiply.modify_lever(modify_lever_params);
        assert!(modify_lever_response.collateral_delta == i257_new(10110_000_000, false));
        assert!(modify_lever_response.debt_delta > i257_new(0, false));
        assert!(modify_lever_response.margin_delta == i257_new(10000_000_000, false));

        let (_, collateral, _) = singleton
            .position(pool_id, usdc.contract_address, eth.contract_address, user);

        let lever_swap: @Swap = (increase_lever_params.lever_swap[0]);
        let lever_swap_amount: u256 = (*lever_swap.token_amount.amount.mag).into();
        assert!(collateral + 1 == increase_lever_params.add_margin.into() + lever_swap_amount);

        assert!(
            usdc.balanceOf(user) == usdc_balance_before - increase_lever_params.add_margin.into()
        );
    }

    #[test]
    #[available_gas(20000000)]
    #[fork("Mainnet")]
    fn test_modify_lever_split_multi_swap() {
        let TestConfig { singleton, multiply, pool_id, eth, usdc, user, .. } = setup();

        let usdc_balance_before = usdc.balanceOf(user);

        usdc.approve(multiply.contract_address, 10000_000_000.into());
        singleton.modify_delegation(pool_id, multiply.contract_address, true);

        let increase_lever_params = IncreaseLeverParams {
            pool_id,
            collateral_asset: usdc.contract_address,
            debt_asset: eth.contract_address,
            user,
            add_margin: 10000_000_000_u128,
            margin_swap: array![],
            margin_swap_limit_amount: 0,
            lever_swap: array![
                Swap {
                    route: array![
                        RouteNode {
                            pool_key: PoolKey {
                                token0: eth.contract_address,
                                token1: usdc.contract_address,
                                fee: 0x68db8bac710cb4000000000000000,
                                tick_spacing: 200,
                                extension: contract_address_const::<0x0>()
                            },
                            sqrt_ratio_limit: MIN_SQRT_RATIO_LIMIT,
                            skip_ahead: 2
                        }
                    ],
                    token_amount: TokenAmount {
                        token: usdc.contract_address,
                        amount: i129_new((55_000_000).try_into().unwrap(), true)
                    },
                },
                Swap {
                    route: array![
                        RouteNode {
                            pool_key: PoolKey {
                                token0: contract_address_const::<
                                    0x4718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d
                                >(),
                                token1: usdc.contract_address,
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
                                token1: eth.contract_address,
                                fee: 0x68db8bac710cb4000000000000000,
                                tick_spacing: 200,
                                extension: contract_address_const::<0x0>()
                            },
                            sqrt_ratio_limit: MAX_SQRT_RATIO_LIMIT,
                            skip_ahead: 0
                        },
                    ],
                    token_amount: TokenAmount {
                        token: usdc.contract_address,
                        amount: i129_new((27_500_000).try_into().unwrap(), true)
                    },
                },
                Swap {
                    route: array![
                        RouteNode {
                            pool_key: PoolKey {
                                token0: contract_address_const::<
                                    0x4718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d
                                >(),
                                token1: usdc.contract_address,
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
                                token1: eth.contract_address,
                                fee: 0x28f5c28f5c28f5c28f5c28f5c28f5c2,
                                tick_spacing: 354892,
                                extension: contract_address_const::<
                                    0x43e4f09c32d13d43a880e85f69f7de93ceda62d6cf2581a582c6db635548fdc
                                >()
                            },
                            sqrt_ratio_limit: MAX_SQRT_RATIO_LIMIT,
                            skip_ahead: 0
                        },
                    ],
                    token_amount: TokenAmount {
                        token: usdc.contract_address,
                        amount: i129_new((13_750_000).try_into().unwrap(), true)
                    },
                },
                Swap {
                    route: array![
                        RouteNode {
                            pool_key: PoolKey {
                                token0: contract_address_const::<
                                    0x4718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d
                                >(),
                                token1: usdc.contract_address,
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
                                token1: eth.contract_address,
                                fee: 0x68db8bac710cb4000000000000000,
                                tick_spacing: 200,
                                extension: contract_address_const::<0x0>()
                            },
                            sqrt_ratio_limit: MAX_SQRT_RATIO_LIMIT,
                            skip_ahead: 0
                        },
                    ],
                    token_amount: TokenAmount {
                        token: usdc.contract_address,
                        amount: i129_new((13_750_000).try_into().unwrap(), true)
                    },
                },
            ],
            lever_swap_limit_amount: 44000000000000000, // 0.044 ETH
        };

        let modify_lever_params = ModifyLeverParams {
            action: ModifyLeverAction::IncreaseLever(increase_lever_params.clone())
        };

        let modify_lever_response = multiply.modify_lever(modify_lever_params);
        assert!(modify_lever_response.collateral_delta == i257_new(10110_000_000, false));
        assert!(modify_lever_response.debt_delta > i257_new(0, false));
        assert!(modify_lever_response.margin_delta == i257_new(10000_000_000, false));

        let (_, collateral, _) = singleton
            .position(pool_id, usdc.contract_address, eth.contract_address, user);

        let lever_swap_1: @Swap = (increase_lever_params.lever_swap[0]);
        let lever_swap_amount_1: u256 = (*lever_swap_1.token_amount.amount.mag).into();
        let lever_swap_2: @Swap = (increase_lever_params.lever_swap[1]);
        let lever_swap_amount_2: u256 = (*lever_swap_2.token_amount.amount.mag).into();
        let lever_swap_3: @Swap = (increase_lever_params.lever_swap[2]);
        let lever_swap_amount_3: u256 = (*lever_swap_3.token_amount.amount.mag).into();
        let lever_swap_4: @Swap = (increase_lever_params.lever_swap[3]);
        let lever_swap_amount_4: u256 = (*lever_swap_4.token_amount.amount.mag).into();
        assert!(
            lever_swap_amount_1
                + lever_swap_amount_2
                + lever_swap_amount_3
                + lever_swap_amount_4 == 110_000_000
        );
        assert!(
            collateral
                + 1 == increase_lever_params.add_margin.into()
                + lever_swap_amount_1
                + lever_swap_amount_2
                + lever_swap_amount_3
                + lever_swap_amount_4
        );

        assert!(
            usdc.balanceOf(user) == usdc_balance_before - increase_lever_params.add_margin.into()
        );
    }

    #[test]
    #[available_gas(20000000)]
    #[should_panic(expected: "limit-amount-exceeded")]
    #[fork("Mainnet")]
    fn test_modify_lever_multi_swap_limit_amount_exceeded() {
        let TestConfig { singleton,
        multiply,
        pool_id,
        pool_key_3,
        pool_key_4,
        eth,
        usdc,
        user,
        .. } =
            setup();

        usdc.approve(multiply.contract_address, 10000_000_000.into());
        singleton.modify_delegation(pool_id, multiply.contract_address, true);

        let increase_lever_params = IncreaseLeverParams {
            pool_id,
            collateral_asset: usdc.contract_address,
            debt_asset: eth.contract_address,
            user,
            add_margin: 10000_000_000_u128,
            margin_swap: array![],
            margin_swap_limit_amount: 0,
            lever_swap: array![
                Swap {
                    route: array![
                        RouteNode {
                            pool_key: pool_key_3,
                            sqrt_ratio_limit: MIN_SQRT_RATIO_LIMIT,
                            skip_ahead: 0
                        },
                        RouteNode {
                            pool_key: pool_key_4,
                            sqrt_ratio_limit: MAX_SQRT_RATIO_LIMIT,
                            skip_ahead: 0
                        }
                    ],
                    token_amount: TokenAmount {
                        token: usdc.contract_address,
                        amount: i129_new((100_000_000).try_into().unwrap(), true)
                    },
                }
            ],
            lever_swap_limit_amount: 10000000000000000, // 0.01 ETH
        };

        let modify_lever_params = ModifyLeverParams {
            action: ModifyLeverAction::IncreaseLever(increase_lever_params.clone())
        };

        multiply.modify_lever(modify_lever_params);
    }

    #[test]
    #[available_gas(20000000)]
    #[fork("Mainnet")]
    fn test_modify_lever_close_multi_swap() {
        let TestConfig { singleton, multiply, pool_id, pool_key, eth, usdc, user, .. } = setup();

        usdc.approve(multiply.contract_address, 10000_000_000.into());
        singleton.modify_delegation(pool_id, multiply.contract_address, true);

        let increase_lever_params = IncreaseLeverParams {
            pool_id,
            collateral_asset: usdc.contract_address,
            debt_asset: eth.contract_address,
            user,
            add_margin: 10000_000_000_u128,
            margin_swap: array![],
            margin_swap_limit_amount: 0,
            lever_swap: array![
                Swap {
                    route: array![
                        RouteNode {
                            pool_key, sqrt_ratio_limit: MIN_SQRT_RATIO_LIMIT, skip_ahead: 0
                        }
                    ],
                    token_amount: TokenAmount {
                        token: usdc.contract_address,
                        amount: i129_new((110_000_000).try_into().unwrap(), true)
                    },
                }
            ],
            lever_swap_limit_amount: 35000000000000000, // 0.035 ETH
        };

        let modify_lever_params = ModifyLeverParams {
            action: ModifyLeverAction::IncreaseLever(increase_lever_params.clone())
        };

        multiply.modify_lever(modify_lever_params);

        let user_balance_before = usdc.balanceOf(user);

        let decrease_lever_params = DecreaseLeverParams {
            pool_id,
            collateral_asset: usdc.contract_address,
            debt_asset: eth.contract_address,
            user,
            sub_margin: 0,
            recipient: user,
            lever_swap: array![
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
                            sqrt_ratio_limit: 0x446634e28eeaa431ae12ec1659450,
                            skip_ahead: 0
                        }
                    ],
                    token_amount: TokenAmount {
                        token: eth.contract_address, amount: Zero::zero(),
                    },
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
                            sqrt_ratio_limit: 0x307e81d097153647a82829cfa5d7901,
                            skip_ahead: 0
                        },
                        RouteNode {
                            pool_key: PoolKey {
                                token0: contract_address_const::<
                                    0x3b405a98c9e795d427fe82cdeeeed803f221b52471e3a757574a2b4180793ee
                                >(),
                                token1: contract_address_const::<
                                    0x4718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d
                                >(),
                                fee: 0xc49ba5e353f7d00000000000000000,
                                tick_spacing: 354892,
                                extension: contract_address_const::<
                                    0x43e4f09c32d13d43a880e85f69f7de93ceda62d6cf2581a582c6db635548fdc
                                >()
                            },
                            sqrt_ratio_limit: 0x131b02323b1a000e3,
                            skip_ahead: 0
                        },
                        RouteNode {
                            pool_key: PoolKey {
                                token0: contract_address_const::<
                                    0x3b405a98c9e795d427fe82cdeeeed803f221b52471e3a757574a2b4180793ee
                                >(),
                                token1: contract_address_const::<
                                    0x53c91253bc9682c04929ca02ed00b3e423f6710d2ee7e0d5ebb06f3ecf368a8
                                >(),
                                fee: 0xc49ba5e353f7d00000000000000000,
                                tick_spacing: 5982,
                                extension: contract_address_const::<0x0>()
                            },
                            sqrt_ratio_limit: 0x9b876e7f2023a3f55e14d63d,
                            skip_ahead: 0
                        }
                    ],
                    token_amount: TokenAmount {
                        token: eth.contract_address, amount: Zero::zero(),
                    },
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
                            sqrt_ratio_limit: 0x307ddc74b2248a73b1f19d7430afe18,
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
                            sqrt_ratio_limit: 0xd48a866dfb39cd5e9d7687efb52,
                            skip_ahead: 0
                        }
                    ],
                    token_amount: TokenAmount {
                        token: eth.contract_address, amount: Zero::zero(),
                    },
                },
            ],
            lever_swap_limit_amount: 110_000_000
                + (110_000_000 * 1 / 100), // 1% slippage of the original levered amount
            lever_swap_weights: array![SCALE_128 / 3, SCALE_128 / 3, SCALE_128 / 3 + 1],
            withdraw_swap: array![],
            withdraw_swap_limit_amount: 0,
            withdraw_swap_weights: array![],
            close_position: true
        };

        let modify_lever_params = ModifyLeverParams {
            action: ModifyLeverAction::DecreaseLever(decrease_lever_params.clone())
        };

        let (_, collateral, debt) = singleton
            .position(pool_id, usdc.contract_address, eth.contract_address, user);

        let modify_lever_response = multiply.modify_lever(modify_lever_params);

        assert!(modify_lever_response.collateral_delta == i257_new(collateral, true));
        assert!(modify_lever_response.debt_delta == i257_new(debt, true));
        assert!(modify_lever_response.margin_delta <= i257_new(9999_000_000, true));

        let (position, collateral, debt) = singleton
            .position(pool_id, usdc.contract_address, eth.contract_address, user);
        assert!(position.collateral_shares == 0);
        assert!(position.nominal_debt == 0);
        assert!(collateral == 0);
        assert!(debt == 0);

        assert!(
            usdc.balanceOf(user) >= user_balance_before + decrease_lever_params.sub_margin.into()
        );
    }
}

