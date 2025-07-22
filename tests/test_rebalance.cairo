use starknet::ContractAddress;

#[starknet::interface]
trait IStarkgateERC20<TContractState> {
    fn permissioned_mint(ref self: TContractState, account: ContractAddress, amount: u256);
}

#[cfg(test)]
mod Test_896150_Rebalance {
    use alexandria_math::i257::I257Trait;
    use core::num::traits::Zero;
    use ekubo::interfaces::core::ICoreDispatcher;
    use ekubo::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use ekubo::types::keys::PoolKey;
    use snforge_std::{CheatSpan, cheat_caller_address, load};
    use starknet::{ContractAddress, get_contract_address};
    use vesu::data_model::{Amount, AmountDenomination, AmountType, ModifyPositionParams};
    use vesu::extension::interface::{IExtensionDispatcher, IExtensionDispatcherTrait};
    use vesu::singleton_v2::{ISingletonV2Dispatcher, ISingletonV2DispatcherTrait};
    use vesu::test::setup_v2::deploy_with_args;
    use vesu::units::{SCALE, SCALE_128};
    use vesu_periphery::i129_new;
    use vesu_periphery::rebalance::{
        IRebalanceDispatcher, IRebalanceDispatcherTrait, RebalanceParams,
    };
    use vesu_periphery::swap::{RouteNode, Swap, TokenAmount};
    use super::{IStarkgateERC20Dispatcher, IStarkgateERC20DispatcherTrait};

    const MIN_SQRT_RATIO_LIMIT: u256 = 18446748437148339061;
    const MAX_SQRT_RATIO_LIMIT: u256 = 6277100250585753475930931601400621808602321654880405518632;

    struct TestConfig {
        ekubo: ICoreDispatcher,
        singleton: ISingletonV2Dispatcher,
        rebalance: IRebalanceDispatcher,
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

    fn setup(fee_rate: u128) -> TestConfig {
        let ekubo = ICoreDispatcher {
            contract_address: 0x00000005dd3D2F4429AF886cD1a3b08289DBcEa99A294197E9eB43b0e0325b
                .try_into()
                .unwrap(),
        };
        let singleton = ISingletonV2Dispatcher {
            contract_address: 0x2545b2e5d519fc230e9cd781046d3a64e092114f07e44771e0d719d148725e
                .try_into()
                .unwrap(),
        };
        let rebalance = IRebalanceDispatcher {
            contract_address: deploy_with_args(
                "Rebalance",
                array![
                    ekubo.contract_address.into(),
                    singleton.contract_address.into(),
                    get_contract_address().into(),
                    fee_rate.into(),
                ],
            ),
        };

        let eth = IERC20Dispatcher {
            contract_address: 0x049d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004d
                .try_into()
                .unwrap(),
        };
        let usdc = IERC20Dispatcher {
            contract_address: 0x053c91253bc9682c04929ca02ed00b3e423f6710d2ee7e0d5ebb06f3ecf368
                .try_into()
                .unwrap(),
        };
        let usdt = IERC20Dispatcher {
            contract_address: 0x068f5c6a61780768455de69077e07e89787839bf8166decfbf92b645209c0f
                .try_into()
                .unwrap(),
        };
        let strk = IERC20Dispatcher {
            contract_address: 0x4718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938
                .try_into()
                .unwrap(),
        };

        let pool_id = 2198503327643286920898110335698706244522220458610657370981979460625005526824;

        let pool_key = PoolKey {
            token0: eth.contract_address,
            token1: usdc.contract_address,
            fee: 170141183460469235273462165868118016,
            tick_spacing: 1000,
            extension: 0x0.try_into().unwrap(),
        };

        let pool_key_2 = PoolKey {
            token0: usdc.contract_address,
            token1: usdt.contract_address,
            fee: 8507159232437450533281168781287096,
            tick_spacing: 25,
            extension: 0x0.try_into().unwrap(),
        };

        let pool_key_3 = PoolKey {
            token0: strk.contract_address,
            token1: usdc.contract_address,
            fee: 34028236692093847977029636859101184,
            tick_spacing: 200,
            extension: 0x0.try_into().unwrap(),
        };

        let pool_key_4 = PoolKey {
            token0: strk.contract_address,
            token1: eth.contract_address,
            fee: 34028236692093847977029636859101184,
            tick_spacing: 200,
            extension: 0x0.try_into().unwrap(),
        };

        let user = get_contract_address();

        let loaded = load(usdc.contract_address, selector!("permitted_minter"), 1);
        let minter: ContractAddress = (*loaded[0]).try_into().unwrap();
        cheat_caller_address(usdc.contract_address, minter, CheatSpan::TargetCalls(1));
        IStarkgateERC20Dispatcher { contract_address: usdc.contract_address }
            .permissioned_mint(user, 10000_000_000);

        let loaded = load(usdt.contract_address, selector!("permitted_minter"), 1);
        let minter: ContractAddress = (*loaded[0]).try_into().unwrap();
        cheat_caller_address((usdt.contract_address), minter, CheatSpan::TargetCalls(1));
        IStarkgateERC20Dispatcher { contract_address: usdt.contract_address }
            .permissioned_mint(user, 10000_000_000);

        rebalance.set_rebalancer(get_contract_address(), true);
        rebalance.set_rebalancer('0x1'.try_into().unwrap(), true);

        let test_config = TestConfig {
            ekubo,
            singleton,
            rebalance,
            pool_id,
            pool_key,
            pool_key_2,
            pool_key_3,
            pool_key_4,
            eth,
            usdc,
            usdt,
            user,
        };

        test_config
    }

    #[test]
    #[available_gas(20000000)]
    #[should_panic(expected: "only-owner")]
    #[fork("Mainnet")]
    fn test_rebalance_set_owner() {
        let TestConfig { rebalance, .. } = setup(0);

        cheat_caller_address(
            rebalance.contract_address, '0x3'.try_into().unwrap(), CheatSpan::TargetCalls(1),
        );
        rebalance.set_owner(get_contract_address());
    }

    #[test]
    #[available_gas(20000000)]
    #[should_panic(expected: "only-owner")]
    #[fork("Mainnet")]
    fn test_rebalance_set_rebalancer() {
        let TestConfig { rebalance, .. } = setup(0);

        cheat_caller_address(
            rebalance.contract_address, '0x3'.try_into().unwrap(), CheatSpan::TargetCalls(1),
        );
        rebalance.set_rebalancer(get_contract_address(), true);
    }

    #[test]
    #[available_gas(20000000)]
    #[should_panic(expected: "only-rebalancer")]
    #[fork("Mainnet")]
    fn test_rebalance_increase_only_rebalancer() {
        let TestConfig { rebalance, pool_id, eth, usdc, user, .. } = setup(0);

        let rebalance_params = RebalanceParams {
            pool_id,
            collateral_asset: usdc.contract_address,
            debt_asset: eth.contract_address,
            user,
            rebalance_swap: array![],
            rebalance_swap_limit_amount: 0,
            fee_recipient: Zero::zero(),
        };

        cheat_caller_address(
            rebalance.contract_address, '0x2'.try_into().unwrap(), CheatSpan::TargetCalls(1),
        );
        rebalance.rebalance_position(rebalance_params.clone());
    }

    #[test]
    #[available_gas(20000000)]
    #[should_panic(expected: "target-ltv-tolerance")]
    #[fork("Mainnet")]
    fn test_rebalance_increase_target_ltv_tolerance() {
        let TestConfig { singleton, rebalance, pool_id, pool_key, eth, usdc, user, .. } = setup(0);

        let target_ltv = (SCALE / 2).try_into().unwrap();
        let target_ltv_tolerance = 0;
        let target_ltv_min_delta = 1;

        cheat_caller_address(rebalance.contract_address, user, CheatSpan::TargetCalls(1));
        rebalance
            .set_target_ltv_config(
                pool_id,
                usdc.contract_address,
                eth.contract_address,
                target_ltv,
                target_ltv_tolerance,
                target_ltv_min_delta,
            );

        usdc.approve(singleton.contract_address, 10000_000_000.into());

        singleton
            .modify_position(
                ModifyPositionParams {
                    pool_id,
                    collateral_asset: usdc.contract_address,
                    debt_asset: eth.contract_address,
                    user,
                    collateral: Amount {
                        amount_type: AmountType::Delta,
                        denomination: AmountDenomination::Assets,
                        value: 10000_000_000.into(),
                    },
                    debt: Default::default(),
                    data: ArrayTrait::new().span(),
                },
            );

        let (_, collateral, debt) = singleton
            .position(pool_id, usdc.contract_address, eth.contract_address, user);
        assert!(collateral == 10000_000_000.into() - 1);
        assert!(debt == 0.into());

        singleton.modify_delegation(pool_id, rebalance.contract_address, true);

        let (_, delta_usd, collateral_delta, debt_delta) = rebalance
            .delta(pool_id, usdc.contract_address, eth.contract_address, user);
        assert!(delta_usd.abs() != 0);

        let rebalance_params = RebalanceParams {
            pool_id,
            collateral_asset: usdc.contract_address,
            debt_asset: eth.contract_address,
            user,
            rebalance_swap: array![
                Swap {
                    route: array![
                        RouteNode {
                            pool_key, sqrt_ratio_limit: MIN_SQRT_RATIO_LIMIT, skip_ahead: 0,
                        },
                    ],
                    token_amount: TokenAmount {
                        token: usdc.contract_address,
                        amount: i129_new((collateral_delta.abs()).try_into().unwrap(), true),
                    },
                },
            ],
            rebalance_swap_limit_amount: debt_delta.abs().try_into().unwrap()
                + (SCALE / 10).try_into().unwrap(), // 3 ETH
            fee_recipient: Zero::zero(),
        };

        rebalance.rebalance_position(rebalance_params.clone());
    }

    #[test]
    #[available_gas(20000000)]
    #[should_panic(expected: "target-ltv-min-delta")]
    #[fork("Mainnet")]
    fn test_rebalance_increase_target_ltv_min_delta() {
        let TestConfig { singleton, rebalance, pool_id, pool_key, eth, usdc, user, .. } = setup(0);

        let target_ltv = (SCALE / 2).try_into().unwrap();
        let target_ltv_tolerance = (SCALE / 100).try_into().unwrap();
        let target_ltv_min_delta = SCALE_128;

        cheat_caller_address(rebalance.contract_address, user, CheatSpan::TargetCalls(1));
        rebalance
            .set_target_ltv_config(
                pool_id,
                usdc.contract_address,
                eth.contract_address,
                target_ltv,
                target_ltv_tolerance,
                target_ltv_min_delta,
            );

        usdc.approve(singleton.contract_address, 10000_000_000.into());

        singleton
            .modify_position(
                ModifyPositionParams {
                    pool_id,
                    collateral_asset: usdc.contract_address,
                    debt_asset: eth.contract_address,
                    user,
                    collateral: Amount {
                        amount_type: AmountType::Delta,
                        denomination: AmountDenomination::Assets,
                        value: 10000_000_000.into(),
                    },
                    debt: Default::default(),
                    data: ArrayTrait::new().span(),
                },
            );

        let (_, collateral, debt) = singleton
            .position(pool_id, usdc.contract_address, eth.contract_address, user);
        assert!(collateral == 10000_000_000.into() - 1);
        assert!(debt == 0.into());

        singleton.modify_delegation(pool_id, rebalance.contract_address, true);

        let (_, delta_usd, collateral_delta, debt_delta) = rebalance
            .delta(pool_id, usdc.contract_address, eth.contract_address, user);
        assert!(delta_usd.abs() != 0);

        let rebalance_params = RebalanceParams {
            pool_id,
            collateral_asset: usdc.contract_address,
            debt_asset: eth.contract_address,
            user,
            rebalance_swap: array![
                Swap {
                    route: array![
                        RouteNode {
                            pool_key, sqrt_ratio_limit: MIN_SQRT_RATIO_LIMIT, skip_ahead: 0,
                        },
                    ],
                    token_amount: TokenAmount {
                        token: usdc.contract_address,
                        amount: i129_new((collateral_delta.abs()).try_into().unwrap(), true),
                    },
                },
            ],
            rebalance_swap_limit_amount: debt_delta.abs().try_into().unwrap()
                + (SCALE / 10).try_into().unwrap(), // 3 ETH
            fee_recipient: Zero::zero(),
        };

        rebalance.rebalance_position(rebalance_params.clone());
    }

    #[test]
    #[available_gas(20000000)]
    #[fork("Mainnet")]
    fn test_rebalance_increase_with_fee() {
        let TestConfig {
            singleton, rebalance, pool_id, pool_key, eth, usdc, user, ..,
        } = setup(SCALE_128 / 100);

        let target_ltv = (SCALE / 2).try_into().unwrap();
        let target_ltv_tolerance = SCALE_128 / 100;
        let target_ltv_min_delta = target_ltv_tolerance + 1;

        cheat_caller_address(rebalance.contract_address, user, CheatSpan::TargetCalls(1));
        rebalance
            .set_target_ltv_config(
                pool_id,
                usdc.contract_address,
                eth.contract_address,
                target_ltv,
                target_ltv_tolerance,
                target_ltv_min_delta,
            );

        usdc.approve(singleton.contract_address, 10000_000_000.into());

        singleton
            .modify_position(
                ModifyPositionParams {
                    pool_id,
                    collateral_asset: usdc.contract_address,
                    debt_asset: eth.contract_address,
                    user,
                    collateral: Amount {
                        amount_type: AmountType::Delta,
                        denomination: AmountDenomination::Assets,
                        value: 10000_000_000.into(),
                    },
                    debt: Default::default(),
                    data: ArrayTrait::new().span(),
                },
            );

        let (_, collateral, debt) = singleton
            .position(pool_id, usdc.contract_address, eth.contract_address, user);
        assert!(collateral == 10000_000_000.into() - 1);
        assert!(debt == 0.into());

        let usdc_balance_before = usdc.balanceOf(user);

        singleton.modify_delegation(pool_id, rebalance.contract_address, true);

        let (_, delta_usd, collateral_delta, debt_delta) = rebalance
            .delta(pool_id, usdc.contract_address, eth.contract_address, user);
        assert!(delta_usd.abs() != 0);

        let rebalancer = '0x1'.try_into().unwrap();

        let rebalance_params = RebalanceParams {
            pool_id,
            collateral_asset: usdc.contract_address,
            debt_asset: eth.contract_address,
            user,
            rebalance_swap: array![
                Swap {
                    route: array![
                        RouteNode {
                            pool_key, sqrt_ratio_limit: MIN_SQRT_RATIO_LIMIT, skip_ahead: 0,
                        },
                    ],
                    token_amount: TokenAmount {
                        token: usdc.contract_address,
                        amount: i129_new((collateral_delta.abs()).try_into().unwrap(), true),
                    },
                },
            ],
            rebalance_swap_limit_amount: debt_delta.abs().try_into().unwrap()
                + (SCALE / 10).try_into().unwrap(), // 3 ETH
            fee_recipient: rebalancer,
        };

        cheat_caller_address(rebalance.contract_address, rebalancer, CheatSpan::TargetCalls(1));
        rebalance.rebalance_position(rebalance_params.clone());

        let (collateral_asset_config, _) = singleton.asset_config(pool_id, usdc.contract_address);
        let (debt_asset_config, _) = singleton.asset_config(pool_id, eth.contract_address);

        let extension = IExtensionDispatcher { contract_address: singleton.extension(pool_id) };

        let collateral_asset_price = extension.price(pool_id, usdc.contract_address);
        let debt_asset_price = extension.price(pool_id, eth.contract_address);

        let collateral_usd = collateral
            * collateral_asset_price.value
            / collateral_asset_config.scale;
        let debt_usd = debt * debt_asset_price.value / debt_asset_config.scale;
        let current_ltv = (debt_usd * SCALE) / collateral_usd;

        assert!(
            (target_ltv < target_ltv_tolerance
                || (target_ltv - target_ltv_tolerance).into() <= current_ltv)
                || current_ltv <= (target_ltv + target_ltv_tolerance).into(),
        );

        assert!(usdc.balanceOf(user) == usdc_balance_before);
        assert!(usdc.balanceOf(rebalancer) > 0);
    }

    #[test]
    #[available_gas(20000000)]
    #[fork("Mainnet")]
    fn test_rebalance_increase_with_fee_split_swap() {
        let TestConfig {
            singleton, rebalance, pool_id, eth, usdc, user, ..,
        } = setup(SCALE_128 / 100);

        let target_ltv = (SCALE / 2).try_into().unwrap();
        let target_ltv_tolerance = (SCALE / 100).try_into().unwrap();
        let target_ltv_min_delta = target_ltv_tolerance + 1;

        cheat_caller_address(rebalance.contract_address, user, CheatSpan::TargetCalls(1));
        rebalance
            .set_target_ltv_config(
                pool_id,
                usdc.contract_address,
                eth.contract_address,
                target_ltv,
                target_ltv_tolerance,
                target_ltv_min_delta,
            );

        usdc.approve(singleton.contract_address, 10000_000_000.into());

        singleton
            .modify_position(
                ModifyPositionParams {
                    pool_id,
                    collateral_asset: usdc.contract_address,
                    debt_asset: eth.contract_address,
                    user,
                    collateral: Amount {
                        amount_type: AmountType::Delta,
                        denomination: AmountDenomination::Assets,
                        value: 10000_000_000.into(),
                    },
                    debt: Default::default(),
                    data: ArrayTrait::new().span(),
                },
            );

        let (_, collateral, debt) = singleton
            .position(pool_id, usdc.contract_address, eth.contract_address, user);
        assert!(collateral == 10000_000_000.into() - 1);
        assert!(debt == 0.into());

        let usdc_balance_before = usdc.balanceOf(user);

        singleton.modify_delegation(pool_id, rebalance.contract_address, true);

        let (_, delta_usd, _, debt_delta) = rebalance
            .delta(pool_id, usdc.contract_address, eth.contract_address, user);
        assert!(delta_usd.abs() != 0);

        let rebalancer = '0x1'.try_into().unwrap();

        let rebalance_params = RebalanceParams {
            pool_id,
            collateral_asset: usdc.contract_address,
            debt_asset: eth.contract_address,
            user,
            rebalance_swap: array![
                Swap {
                    route: array![
                        RouteNode {
                            pool_key: PoolKey {
                                token0: 0x49d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7
                                    .try_into()
                                    .unwrap(),
                                token1: 0x53c91253bc9682c04929ca02ed00b3e423f6710d2ee7e0d5ebb06f3ecf368a8
                                    .try_into()
                                    .unwrap(),
                                fee: 0x20c49ba5e353f80000000000000000.try_into().unwrap(),
                                tick_spacing: 1000,
                                extension: 0x0.try_into().unwrap(),
                            },
                            sqrt_ratio_limit: MIN_SQRT_RATIO_LIMIT,
                            skip_ahead: 0,
                        },
                    ],
                    token_amount: TokenAmount {
                        token: usdc.contract_address,
                        amount: i129_new((7421874999).try_into().unwrap(), true),
                    },
                },
                Swap {
                    route: array![
                        RouteNode {
                            pool_key: PoolKey {
                                token0: 0x4718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938
                                    .try_into()
                                    .unwrap(),
                                token1: 0x53c91253bc9682c04929ca02ed00b3e423f6710d2ee7e0d5ebb06f3ecf368a
                                    .try_into()
                                    .unwrap(),
                                fee: 0x20c49ba5e353f80000000000000000,
                                tick_spacing: 1000,
                                extension: 0x0.try_into().unwrap(),
                            },
                            sqrt_ratio_limit: MIN_SQRT_RATIO_LIMIT,
                            skip_ahead: 0,
                        },
                        RouteNode {
                            pool_key: PoolKey {
                                token0: 0x4718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938
                                    .try_into()
                                    .unwrap(),
                                token1: 0x49d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc
                                    .try_into()
                                    .unwrap(),
                                fee: 0x68db8bac710cb4000000000000000,
                                tick_spacing: 200,
                                extension: 0x0.try_into().unwrap(),
                            },
                            sqrt_ratio_limit: MAX_SQRT_RATIO_LIMIT,
                            skip_ahead: 0,
                        },
                    ],
                    token_amount: TokenAmount {
                        token: usdc.contract_address,
                        amount: i129_new((2500000000).try_into().unwrap(), true),
                    },
                },
                Swap {
                    route: array![
                        RouteNode {
                            pool_key: PoolKey {
                                token0: 0x49d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc
                                    .try_into()
                                    .unwrap(),
                                token1: 0x53c91253bc9682c04929ca02ed00b3e423f6710d2ee7e0d5ebb06f3ecf368a
                                    .try_into()
                                    .unwrap(),
                                fee: 0x68db8bac710cb4000000000000000,
                                tick_spacing: 200,
                                extension: 0x0.try_into().unwrap(),
                            },
                            sqrt_ratio_limit: MIN_SQRT_RATIO_LIMIT,
                            skip_ahead: 3,
                        },
                    ],
                    token_amount: TokenAmount {
                        token: usdc.contract_address,
                        amount: i129_new((78125000).try_into().unwrap(), true),
                    },
                },
            ],
            rebalance_swap_limit_amount: debt_delta.abs().try_into().unwrap()
                + (SCALE / 10).try_into().unwrap(), // 3 ETH
            fee_recipient: rebalancer,
        };

        cheat_caller_address(rebalance.contract_address, rebalancer, CheatSpan::TargetCalls(1));
        rebalance.rebalance_position(rebalance_params.clone());

        let (collateral_asset_config, _) = singleton.asset_config(pool_id, usdc.contract_address);
        let (debt_asset_config, _) = singleton.asset_config(pool_id, eth.contract_address);

        let extension = IExtensionDispatcher { contract_address: singleton.extension(pool_id) };

        let collateral_asset_price = extension.price(pool_id, usdc.contract_address);
        let debt_asset_price = extension.price(pool_id, eth.contract_address);

        let collateral_usd = collateral
            * collateral_asset_price.value
            / collateral_asset_config.scale;
        let debt_usd = debt * debt_asset_price.value / debt_asset_config.scale;
        let current_ltv = (debt_usd * SCALE) / collateral_usd;

        assert!(
            (target_ltv < target_ltv_tolerance
                || (target_ltv - target_ltv_tolerance).into() <= current_ltv)
                || current_ltv <= (target_ltv + target_ltv_tolerance).into(),
        );

        assert!(usdc.balanceOf(user) == usdc_balance_before);
        assert!(usdc.balanceOf(rebalancer) > 0);
    }

    #[test]
    #[available_gas(20000000)]
    #[fork("Mainnet")]
    fn test_rebalance_decrease_with_fee() {
        let TestConfig {
            singleton, rebalance, pool_id, pool_key, eth, usdc, user, ..,
        } = setup(SCALE_128 / 100);

        let target_ltv = (SCALE / 4).try_into().unwrap();
        let target_ltv_tolerance = (SCALE / 100).try_into().unwrap();
        let target_ltv_min_delta = target_ltv_tolerance + 1;

        cheat_caller_address((rebalance.contract_address), user, CheatSpan::TargetCalls(1));
        rebalance
            .set_target_ltv_config(
                pool_id,
                usdc.contract_address,
                eth.contract_address,
                target_ltv,
                target_ltv_tolerance,
                target_ltv_min_delta,
            );

        usdc.approve(singleton.contract_address, 10000_000_000.into());

        singleton
            .modify_position(
                ModifyPositionParams {
                    pool_id,
                    collateral_asset: usdc.contract_address,
                    debt_asset: eth.contract_address,
                    user,
                    collateral: Amount {
                        amount_type: AmountType::Delta,
                        denomination: AmountDenomination::Assets,
                        value: 10000_000_000.into(),
                    },
                    debt: Amount {
                        amount_type: AmountType::Delta,
                        denomination: AmountDenomination::Assets,
                        value: (146 * SCALE / 100).into() // 1.46 ETH
                    },
                    data: ArrayTrait::new().span(),
                },
            );

        let (_, collateral, debt) = singleton
            .position(pool_id, usdc.contract_address, eth.contract_address, user);
        assert!(collateral == 10000_000_000.into() - 1);
        assert!(debt - 1 == (146 * SCALE / 100).into());

        let usdc_balance_before = usdc.balanceOf(user);

        singleton.modify_delegation(pool_id, rebalance.contract_address, true);

        let (_, delta_usd, collateral_delta, _) = rebalance
            .delta(pool_id, usdc.contract_address, eth.contract_address, user);
        assert!(delta_usd.abs() != 0);

        let rebalancer = '0x1'.try_into().unwrap();

        let rebalance_params = RebalanceParams {
            pool_id,
            collateral_asset: usdc.contract_address,
            debt_asset: eth.contract_address,
            user,
            rebalance_swap: array![
                Swap {
                    route: array![
                        RouteNode {
                            pool_key, sqrt_ratio_limit: MAX_SQRT_RATIO_LIMIT, skip_ahead: 0,
                        },
                    ],
                    token_amount: TokenAmount {
                        token: usdc.contract_address,
                        amount: i129_new(collateral_delta.abs().try_into().unwrap(), false),
                    },
                },
            ],
            rebalance_swap_limit_amount: 0,
            fee_recipient: rebalancer,
        };

        cheat_caller_address(rebalance.contract_address, rebalancer, CheatSpan::TargetCalls(1));
        rebalance.rebalance_position(rebalance_params.clone());

        let (collateral_asset_config, _) = singleton.asset_config(pool_id, usdc.contract_address);
        let (debt_asset_config, _) = singleton.asset_config(pool_id, eth.contract_address);

        let extension = IExtensionDispatcher { contract_address: singleton.extension(pool_id) };

        let collateral_asset_price = extension.price(pool_id, usdc.contract_address);
        let debt_asset_price = extension.price(pool_id, eth.contract_address);

        let collateral_usd = collateral
            * collateral_asset_price.value
            / collateral_asset_config.scale;
        let debt_usd = debt * debt_asset_price.value / debt_asset_config.scale;
        let current_ltv = (debt_usd * SCALE) / collateral_usd;

        assert!(
            (target_ltv < target_ltv_tolerance
                || (target_ltv - target_ltv_tolerance).into() <= current_ltv)
                || current_ltv <= (target_ltv + target_ltv_tolerance).into(),
        );

        assert!(usdc.balanceOf(user) == usdc_balance_before);
        assert!(eth.balanceOf(rebalancer) > 0);
    }

    #[test]
    #[available_gas(20000000)]
    #[fork("Mainnet")]
    fn test_rebalance_decrease_split_swap() {
        let TestConfig { singleton, rebalance, pool_id, eth, usdc, user, .. } = setup(0);

        let target_ltv = (SCALE / 4).try_into().unwrap();
        let target_ltv_tolerance = (SCALE / 10).try_into().unwrap();
        let target_ltv_min_delta = target_ltv_tolerance + 1;

        cheat_caller_address(rebalance.contract_address, user, CheatSpan::TargetCalls(1));
        rebalance
            .set_target_ltv_config(
                pool_id,
                usdc.contract_address,
                eth.contract_address,
                target_ltv,
                target_ltv_tolerance,
                target_ltv_min_delta,
            );

        usdc.approve(singleton.contract_address, 10000_000_000.into());

        singleton
            .modify_position(
                ModifyPositionParams {
                    pool_id,
                    collateral_asset: usdc.contract_address,
                    debt_asset: eth.contract_address,
                    user,
                    collateral: Amount {
                        amount_type: AmountType::Delta,
                        denomination: AmountDenomination::Assets,
                        value: 10000_000_000.into(),
                    },
                    debt: Amount {
                        amount_type: AmountType::Delta,
                        denomination: AmountDenomination::Assets,
                        value: (146 * SCALE / 100).into() // 1.46 ETH
                    },
                    data: ArrayTrait::new().span(),
                },
            );

        let (_, collateral, debt) = singleton
            .position(pool_id, usdc.contract_address, eth.contract_address, user);
        assert!(collateral == 10000_000_000.into() - 1);
        assert!(debt - 1 == (146 * SCALE / 100).into());

        let usdc_balance_before = usdc.balanceOf(user);

        singleton.modify_delegation(pool_id, rebalance.contract_address, true);

        let (_, delta_usd, _, _) = rebalance
            .delta(pool_id, usdc.contract_address, eth.contract_address, user);
        assert!(delta_usd.abs() != 0);

        let rebalance_params = RebalanceParams {
            pool_id,
            collateral_asset: usdc.contract_address,
            debt_asset: eth.contract_address,
            user,
            rebalance_swap: array![
                Swap {
                    route: array![
                        RouteNode {
                            pool_key: PoolKey {
                                token0: 0x4718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d
                                    .try_into()
                                    .unwrap(),
                                token1: 0x53c91253bc9682c04929ca02ed00b3e423f6710d2ee7e0d5ebb06f3ecf368a8
                                    .try_into()
                                    .unwrap(),
                                fee: 0x68db8bac710cb4000000000000000,
                                tick_spacing: 200,
                                extension: 0x0.try_into().unwrap(),
                            },
                            sqrt_ratio_limit: MAX_SQRT_RATIO_LIMIT,
                            skip_ahead: 0,
                        },
                        RouteNode {
                            pool_key: PoolKey {
                                token0: 0x4718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938
                                    .try_into()
                                    .unwrap(),
                                token1: 0x49d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc
                                    .try_into()
                                    .unwrap(),
                                fee: 0x68db8bac710cb4000000000000000,
                                tick_spacing: 200,
                                extension: 0x0.try_into().unwrap(),
                            },
                            sqrt_ratio_limit: MIN_SQRT_RATIO_LIMIT,
                            skip_ahead: 0,
                        },
                    ],
                    token_amount: TokenAmount {
                        token: usdc.contract_address,
                        amount: i129_new((2691187944).try_into().unwrap(), false),
                    },
                },
                Swap {
                    route: array![
                        RouteNode {
                            pool_key: PoolKey {
                                token0: 0x49d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc
                                    .try_into()
                                    .unwrap(),
                                token1: 0x53c91253bc9682c04929ca02ed00b3e423f6710d2ee7e0d5ebb06f3ecf368a
                                    .try_into()
                                    .unwrap(),
                                fee: 0x68db8bac710cb4000000000000000,
                                tick_spacing: 200,
                                extension: 0x0.try_into().unwrap(),
                            },
                            sqrt_ratio_limit: MAX_SQRT_RATIO_LIMIT,
                            skip_ahead: 0,
                        },
                    ],
                    token_amount: TokenAmount {
                        token: usdc.contract_address,
                        amount: i129_new((200000000).try_into().unwrap(), false),
                    },
                },
            ],
            rebalance_swap_limit_amount: 0,
            fee_recipient: Zero::zero(),
        };

        rebalance.rebalance_position(rebalance_params.clone());
        let (collateral_asset_config, _) = singleton.asset_config(pool_id, usdc.contract_address);
        let (debt_asset_config, _) = singleton.asset_config(pool_id, eth.contract_address);

        let extension = IExtensionDispatcher { contract_address: singleton.extension(pool_id) };

        let collateral_asset_price = extension.price(pool_id, usdc.contract_address);
        let debt_asset_price = extension.price(pool_id, eth.contract_address);

        let collateral_usd = collateral
            * collateral_asset_price.value
            / collateral_asset_config.scale;
        let debt_usd = debt * debt_asset_price.value / debt_asset_config.scale;
        let current_ltv = (debt_usd * SCALE) / collateral_usd;

        assert!(
            (target_ltv < target_ltv_tolerance
                || (target_ltv - target_ltv_tolerance).into() <= current_ltv)
                || current_ltv <= (target_ltv + target_ltv_tolerance).into(),
        );

        assert!(usdc.balanceOf(user) == usdc_balance_before);
    }
}

