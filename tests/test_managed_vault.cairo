use starknet::ContractAddress;

#[starknet::interface]
trait IStarkgateERC20<TContractState> {
    fn permissioned_mint(ref self: TContractState, account: ContractAddress, amount: u256);
}

#[cfg(test)]
mod Test_896150_ManagedVault {
    use alexandria_math::i257::I257Trait;
    use ekubo::interfaces::core::ICoreDispatcher;
    use ekubo::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use ekubo::types::keys::PoolKey;
    use snforge_std::{CheatSpan, cheat_caller_address, load};
    use starknet::{ContractAddress, get_contract_address};
    use vesu::data_model::{Amount, AmountDenomination, AmountType};
    use vesu::extension::interface::{IExtensionDispatcher, IExtensionDispatcherTrait};
    use vesu::singleton_v2::{ISingletonV2Dispatcher, ISingletonV2DispatcherTrait};
    use vesu::test::setup_v2::deploy_with_args;
    use vesu::units::SCALE;
    use vesu_periphery::managed_vault::{IManagedVaultDispatcher, IManagedVaultDispatcherTrait};
    use vesu_periphery::multiply::IMultiplyDispatcher;
    use super::{IStarkgateERC20Dispatcher, IStarkgateERC20DispatcherTrait};

    const MIN_SQRT_RATIO_LIMIT: u256 = 18446748437148339061;
    const MAX_SQRT_RATIO_LIMIT: u256 = 6277100250585753475930931601400621808602321654880405518632;

    struct TestConfig {
        ekubo: ICoreDispatcher,
        singleton: ISingletonV2Dispatcher,
        multiply: IMultiplyDispatcher,
        managed_vault: IManagedVaultDispatcher,
        pool_id: felt252,
        pool_key: PoolKey,
        eth: IERC20Dispatcher,
        usdc: IERC20Dispatcher,
        usdt: IERC20Dispatcher,
        user: ContractAddress,
    }

    fn setup() -> TestConfig {
        let ekubo = ICoreDispatcher {
            contract_address: 0x00000005dd3D2F4429AF886cD1a3b08289DBcEa99A294197E9eB43b0e0325b4b
                .try_into()
                .unwrap(),
        };
        let singleton = ISingletonV2Dispatcher {
            contract_address: 0x2545b2e5d519fc230e9cd781046d3a64e092114f07e44771e0d719d148725ef
                .try_into()
                .unwrap(),
        };
        let multiply = IMultiplyDispatcher {
            contract_address: deploy_with_args(
                "Multiply",
                array![ekubo.contract_address.into(), singleton.contract_address.into()],
            ),
        };

        let eth = IERC20Dispatcher {
            contract_address: 0x049d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7
                .try_into()
                .unwrap(),
        };
        let usdc = IERC20Dispatcher {
            contract_address: 0x053c91253bc9682c04929ca02ed00b3e423f6710d2ee7e0d5ebb06f3ecf368a8
                .try_into()
                .unwrap(),
        };
        let usdt = IERC20Dispatcher {
            contract_address: 0x068f5c6a61780768455de69077e07e89787839bf8166decfbf92b645209c0fb8
                .try_into()
                .unwrap(),
        };
        // let strk = IERC20Dispatcher {
        //     contract_address: contract_address_const::<
        //         0x4718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d
        //     >()
        // };

        let pool_id = 2198503327643286920898110335698706244522220458610657370981979460625005526824;

        let pool_key = PoolKey {
            token0: eth.contract_address,
            token1: usdc.contract_address,
            fee: 170141183460469235273462165868118016,
            tick_spacing: 1000,
            extension: 0x0.try_into().unwrap(),
        };

        let calldata: Array<felt252> = array![
            'MVault',
            'MVault',
            18.into(),
            usdc.contract_address.into(),
            false.into(),
            get_contract_address().into(),
            get_contract_address().into(),
            singleton.contract_address.into(),
            ekubo.contract_address.into(),
            multiply.contract_address.into(),
            0,
        ];

        let managed_vault = IManagedVaultDispatcher {
            contract_address: deploy_with_args("ManagedVault", calldata),
        };
        managed_vault.set_price_source(singleton.extension(pool_id), pool_id);

        let user = get_contract_address();

        let loaded = load(usdc.contract_address, selector!("permitted_minter"), 1);
        let minter: ContractAddress = (*loaded[0]).try_into().unwrap();
        cheat_caller_address(usdc.contract_address, minter, CheatSpan::TargetCalls(1));
        IStarkgateERC20Dispatcher { contract_address: usdc.contract_address }
            .permissioned_mint(user, 10000_000_000);

        let loaded = load(usdt.contract_address, selector!("permitted_minter"), 1);
        let minter: ContractAddress = (*loaded[0]).try_into().unwrap();
        cheat_caller_address(usdt.contract_address, minter, CheatSpan::TargetCalls(1));
        IStarkgateERC20Dispatcher { contract_address: usdt.contract_address }
            .permissioned_mint(user, 10010_000_000);

        let test_config = TestConfig {
            ekubo, singleton, multiply, managed_vault, pool_id, pool_key, eth, usdc, usdt, user,
        };

        test_config
    }

    #[test]
    #[available_gas(20000000)]
    #[fork("Mainnet")]
    fn test_managed_vault_deposit() {
        let TestConfig {
            singleton, multiply, managed_vault, pool_id, pool_key, eth, usdc, user, ..,
        } = setup();

        let usdc_balance_before = usdc.balanceOf(user);

        usdc.approve(managed_vault.contract_address, 10000_000_000.into());

        managed_vault.deposit(10000_000_000.into(), user);
        assert!(usdc.balanceOf(managed_vault.contract_address) == 10000_000_000.into());
        assert!(
            IERC20Dispatcher { contract_address: managed_vault.contract_address }
                .balanceOf(user) == 10000
                * SCALE,
        );

        let (extension, pool_id) = managed_vault.price_source();
        let price = IExtensionDispatcher { contract_address: extension }
            .price(pool_id, usdc.contract_address);

        assert!(managed_vault.nav() >= 10000 * price.value);

        managed_vault
            .modify_position(
                pool_id,
                collateral_asset: usdc.contract_address,
                debt_asset: eth.contract_address,
                collateral: Amount {
                    amount_type: AmountType::Delta,
                    denomination: AmountDenomination::Assets,
                    value: I257Trait::new(10000_000_000, false),
                },
                debt: Amount {
                    amount_type: AmountType::Delta,
                    denomination: AmountDenomination::Assets,
                    value: I257Trait::new(0, false),
                },
            );

        assert!(managed_vault.nav() >= 10000 * price.value - 10000000000000);

        managed_vault
            .modify_position(
                pool_id,
                collateral_asset: usdc.contract_address,
                debt_asset: eth.contract_address,
                collateral: Amount {
                    amount_type: AmountType::Target,
                    denomination: AmountDenomination::Assets,
                    value: I257Trait::new(0, false),
                },
                debt: Amount {
                    amount_type: AmountType::Delta,
                    denomination: AmountDenomination::Assets,
                    value: I257Trait::new(0, false),
                },
            );

        assert!(managed_vault.nav() >= 10000 * price.value - 10000000000000);

        managed_vault
            .request_redeem(
                IERC20Dispatcher { contract_address: managed_vault.contract_address }
                    .balanceOf(user),
            );

        managed_vault.redeem(user, user);
        // assert!(managed_vault.nav() == 0.into());

        // singleton.modify_delegation(pool_id, multiply.contract_address, true);

        // let increase_lever_params = IncreaseLeverParams {
    //     pool_id,
    //     collateral_asset: usdc.contract_address,
    //     debt_asset: eth.contract_address,
    //     user,
    //     add_margin: 10000_000_000_u128,
    //     margin_swap: array![],
    //     margin_swap_limit_amount: 0,
    //     lever_swap: array![
    //         Swap {
    //             route: array![
    //                 RouteNode {
    //                     pool_key, sqrt_ratio_limit: MIN_SQRT_RATIO_LIMIT, skip_ahead: 0
    //                 }
    //             ],
    //             token_amount: TokenAmount {
    //                 token: usdc.contract_address,
    //                 amount: i129_new((110_000_000).try_into().unwrap(), true)
    //             }
    //         }
    //     ],
    //     lever_swap_limit_amount: 44000000000000000, // 0.044 ETH
    // };

        // let modify_lever_params = ModifyLeverParams {
    //     action: ModifyLeverAction::IncreaseLever(increase_lever_params.clone())
    // };

        // multiply.modify_lever(modify_lever_params);

        // let (_, collateral, _) = singleton
    //     .position(pool_id, usdc.contract_address, eth.contract_address, user);

        // let y: @Swap = (increase_lever_params.lever_swap[0]);
    // let x: u256 = (*y.token_amount.amount.mag).into();
    // assert!(collateral + 1 == increase_lever_params.add_margin.into() + x);

        // assert!(
    //     usdc.balanceOf(user) == usdc_balance_before - increase_lever_params.add_margin.into()
    // );
    }
}
