use starknet::{ContractAddress};

#[starknet::interface]
trait IStarkgateERC20<TContractState> {
    fn permissioned_mint(ref self: TContractState, account: ContractAddress, amount: u256);
}

#[cfg(test)]
mod Test_974640_Multiply4626 {
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
        common::{i257, i257_new},
        extension::default_extension_po::{
            IDefaultExtensionDispatcher, IDefaultExtensionDispatcherTrait
        }
    };
    use vesu_periphery::multiply4626::{
        IMultiply4626Dispatcher, IMultiply4626DispatcherTrait, ModifyLeverParams,
        IncreaseLeverParams, ModifyLeverAction, I4626Dispatcher, I4626DispatcherTrait
    };
    use vesu_periphery::swap::{RouteNode, TokenAmount, Swap};

    use super::{IStarkgateERC20Dispatcher, IStarkgateERC20DispatcherTrait};

    const MIN_SQRT_RATIO_LIMIT: u256 = 18446748437148339061;
    const MAX_SQRT_RATIO_LIMIT: u256 = 6277100250585753475930931601400621808602321654880405518632;

    struct TestConfig {
        ekubo: ICoreDispatcher,
        singleton: ISingletonDispatcher,
        extension: IDefaultExtensionDispatcher,
        multiply: IMultiply4626Dispatcher,
        pool_id: felt252,
        pool_key: PoolKey,
        pool_key_2: PoolKey,
        pool_key_3: PoolKey,
        pool_key_4: PoolKey,
        eth: IERC20Dispatcher,
        usdc: IERC20Dispatcher,
        usdt: IERC20Dispatcher,
        strk: IERC20Dispatcher,
        xstrk: IERC20Dispatcher,
        sstrk: IERC20Dispatcher,
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
        let multiply = IMultiply4626Dispatcher {
            contract_address: deploy_with_args(
                "Multiply4626",
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
        let xstrk = IERC20Dispatcher {
            contract_address: contract_address_const::<
                0x028d709c875c0ceac3dce7065bec5328186dc89fe254527084d1689910954b0a
            >()
        };
        let sstrk = IERC20Dispatcher {
            contract_address: contract_address_const::<
                0x0356f304b154d29d2a8fe22f1cb9107a9b564a733cf6b4cc47fd121ac1af90c9
            >()
        };

        let pool_id = 2345856225134458665876812536882617294246962319062565703131100435311373119841;

        let extension = IDefaultExtensionDispatcher {
            contract_address: singleton.extension(pool_id)
        };

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

        let loaded = load(strk.contract_address, selector!("permitted_minter"), 1);
        let minter: ContractAddress = (*loaded[0]).try_into().unwrap();
        start_prank(CheatTarget::One(strk.contract_address), minter);
        IStarkgateERC20Dispatcher { contract_address: strk.contract_address }
            .permissioned_mint(user, 10000 * SCALE);
        stop_prank(CheatTarget::One(strk.contract_address));

        let loaded = load(usdc.contract_address, selector!("permitted_minter"), 1);
        let minter: ContractAddress = (*loaded[0]).try_into().unwrap();
        start_prank(CheatTarget::One(usdc.contract_address), minter);
        IStarkgateERC20Dispatcher { contract_address: usdc.contract_address }
            .permissioned_mint(user, 10000_000_000);
        stop_prank(CheatTarget::One(usdc.contract_address));

        let test_config = TestConfig {
            ekubo,
            singleton,
            extension,
            multiply,
            pool_id,
            pool_key,
            pool_key_2,
            pool_key_3,
            pool_key_4,
            eth,
            usdc,
            usdt,
            strk,
            xstrk,
            sstrk,
            user
        };

        test_config
    }

    #[test]
    #[available_gas(20000000)]
    #[fork("Mainnet")]
    fn test_modify_lever_4626_xstrk_no_flash_loan() {
        let TestConfig { singleton, extension, multiply, pool_id, strk, xstrk, user, .. } = setup();

        start_prank(CheatTarget::One(extension.contract_address), extension.pool_owner(pool_id));
        extension
            .set_debt_cap(pool_id, xstrk.contract_address, strk.contract_address, 10000000 * SCALE);
        stop_prank(CheatTarget::One(extension.contract_address));

        let strk_balance_before = strk.balanceOf(user);

        strk.approve(multiply.contract_address, 1000000 * SCALE);
        singleton.modify_delegation(pool_id, multiply.contract_address, true);

        let increase_lever_params = IncreaseLeverParams {
            pool_id,
            collateral_asset: xstrk.contract_address,
            user,
            add_margin: 100 * SCALE_128,
            add_margin_is_wrapped: false,
            margin_swap: array![],
            margin_swap_limit_amount: 0,
            lever_amount: 0
        };

        let modify_lever_params = ModifyLeverParams {
            action: ModifyLeverAction::IncreaseLever(increase_lever_params.clone())
        };

        multiply.modify_lever(modify_lever_params);

        let (_, _, debt) = singleton
            .position(pool_id, xstrk.contract_address, strk.contract_address, user);

        assert!(debt == 0);
        assert!(
            strk.balanceOf(user) == strk_balance_before - increase_lever_params.add_margin.into()
        );
    }

    // #[test]
    // #[available_gas(20000000)]
    // #[fork("Mainnet")]
    // fn test_modify_lever_4626_sstrk_no_flash_loan() {
    //     let TestConfig { singleton, extension, multiply, pool_id, strk, sstrk, user, .. } = setup();

    //     start_prank(CheatTarget::One(extension.contract_address), extension.pool_owner(pool_id));
    //     extension
    //         .set_debt_cap(pool_id, sstrk.contract_address, strk.contract_address, 10000000 * SCALE);
    //     stop_prank(CheatTarget::One(extension.contract_address));

    //     let strk_balance_before = strk.balanceOf(user);

    //     strk.approve(multiply.contract_address, 1000000 * SCALE);
    //     singleton.modify_delegation(pool_id, multiply.contract_address, true);

    //     let increase_lever_params = IncreaseLeverParams {
    //         pool_id,
    //         collateral_asset: sstrk.contract_address,
    //         user,
    //         add_margin: 100 * SCALE_128,
    //         margin_swap: array![],
    //         margin_swap_limit_amount: 0,
    //         lever_amount: 0
    //     };

    //     let modify_lever_params = ModifyLeverParams {
    //         action: ModifyLeverAction::IncreaseLever(increase_lever_params.clone())
    //     };

    //     multiply.modify_lever(modify_lever_params);

    //     let (_, _, debt) = singleton
    //         .position(pool_id, sstrk.contract_address, strk.contract_address, user);

    //     assert!(debt == 0);
    //     assert!(
    //         strk.balanceOf(user) == strk_balance_before - increase_lever_params.add_margin.into()
    //     );
    // }

    #[test]
    #[available_gas(20000000)]
    #[fork("Mainnet")]
    fn test_modify_lever_4626_xstrk() {
        let TestConfig { singleton, extension, multiply, pool_id, strk, xstrk, user, .. } = setup();

        start_prank(CheatTarget::One(extension.contract_address), extension.pool_owner(pool_id));
        extension
            .set_debt_cap(pool_id, xstrk.contract_address, strk.contract_address, 10000000 * SCALE);
        stop_prank(CheatTarget::One(extension.contract_address));

        let strk_balance_before = strk.balanceOf(user);

        strk.approve(multiply.contract_address, 1000000 * SCALE);
        singleton.modify_delegation(pool_id, multiply.contract_address, true);

        let increase_lever_params = IncreaseLeverParams {
            pool_id,
            collateral_asset: xstrk.contract_address,
            user,
            add_margin: 100 * SCALE_128,
            add_margin_is_wrapped: false,
            margin_swap: array![],
            margin_swap_limit_amount: 0,
            lever_amount: 400 * SCALE_128
        };

        let modify_lever_params = ModifyLeverParams {
            action: ModifyLeverAction::IncreaseLever(increase_lever_params.clone())
        };

        multiply.modify_lever(modify_lever_params);

        let (_, _, debt) = singleton
            .position(pool_id, xstrk.contract_address, strk.contract_address, user);

        assert!(debt - 1 == increase_lever_params.lever_amount.into());
        assert!(
            strk.balanceOf(user) == strk_balance_before - increase_lever_params.add_margin.into()
        );
    }

    #[test]
    #[available_gas(20000000)]
    #[fork("Mainnet")]
    fn test_modify_lever_4626_xstrk_margin_swap() {
        let TestConfig { singleton, extension, multiply, pool_id, usdc, strk, xstrk, user, .. } =
            setup();

        start_prank(CheatTarget::One(extension.contract_address), extension.pool_owner(pool_id));
        extension
            .set_debt_cap(pool_id, xstrk.contract_address, strk.contract_address, 10000000 * SCALE);
        stop_prank(CheatTarget::One(extension.contract_address));

        let strk_balance_before = strk.balanceOf(user);

        strk.approve(multiply.contract_address, 1000000 * SCALE);
        usdc.approve(multiply.contract_address, 100_000_000);
        singleton.modify_delegation(pool_id, multiply.contract_address, true);

        let increase_lever_params = IncreaseLeverParams {
            pool_id,
            collateral_asset: xstrk.contract_address,
            user,
            add_margin: 0,
            add_margin_is_wrapped: false,
            margin_swap: array![
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
                        },
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
                            sqrt_ratio_limit: MAX_SQRT_RATIO_LIMIT,
                            skip_ahead: 0
                        },
                    ],
                    token_amount: TokenAmount {
                        token: usdc.contract_address,
                        amount: i129_new((100_000_000).try_into().unwrap(), false)
                    },
                }
            ],
            margin_swap_limit_amount: 0,
            lever_amount: 400 * SCALE_128
        };

        let modify_lever_params = ModifyLeverParams {
            action: ModifyLeverAction::IncreaseLever(increase_lever_params.clone())
        };

        multiply.modify_lever(modify_lever_params);

        let (_, _, debt) = singleton
            .position(pool_id, xstrk.contract_address, strk.contract_address, user);

        assert!(debt - 1 == increase_lever_params.lever_amount.into());
        assert!(
            strk.balanceOf(user) == strk_balance_before - increase_lever_params.add_margin.into()
        );
    }

    #[test]
    #[available_gas(20000000)]
    #[fork("Mainnet")]
    fn test_modify_lever_4626_xstrk_wrapped_margin() {
        let TestConfig { singleton, extension, multiply, pool_id, strk, xstrk, user, .. } = setup();

        start_prank(CheatTarget::One(extension.contract_address), extension.pool_owner(pool_id));
        extension
            .set_debt_cap(pool_id, xstrk.contract_address, strk.contract_address, 10000000 * SCALE);
        stop_prank(CheatTarget::One(extension.contract_address));

        let strk_balance_before = strk.balanceOf(user);

        strk.approve(xstrk.contract_address, 100 * SCALE);
        // println!("{}", I4626Dispatcher { contract_address: xstrk.contract_address }.deposit(100 * SCALE, user));
        I4626Dispatcher { contract_address: xstrk.contract_address }.deposit(100 * SCALE, user);
        xstrk.approve(multiply.contract_address, 100 * SCALE);

        singleton.modify_delegation(pool_id, multiply.contract_address, true);

        let increase_lever_params = IncreaseLeverParams {
            pool_id,
            collateral_asset: xstrk.contract_address,
            user,
            add_margin: 99 * SCALE_128,
            add_margin_is_wrapped: true,
            margin_swap: array![],
            margin_swap_limit_amount: 0,
            lever_amount: 400 * SCALE_128
        };

        let modify_lever_params = ModifyLeverParams {
            action: ModifyLeverAction::IncreaseLever(increase_lever_params.clone())
        };

        multiply.modify_lever(modify_lever_params);

        let (_, _, debt) = singleton
            .position(pool_id, xstrk.contract_address, strk.contract_address, user);

        assert!(debt - 1 == increase_lever_params.lever_amount.into());
        assert!(strk.balanceOf(user) == strk_balance_before - 100 * SCALE);
    }
}
