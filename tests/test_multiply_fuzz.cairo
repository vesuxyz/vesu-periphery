#[cfg(test)]
mod Test_896150_Multiply {
    use snforge_std::{start_prank, stop_prank, start_warp, stop_warp, CheatTarget, load, declare, ContractClass, ContractClassTrait};
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
        test::setup::deploy_with_args,
        common::{i257, i257_new},
        math::{pow_10},
    };
    use vesu_periphery::multiply::{
        IMultiplyDispatcher, IMultiplyDispatcherTrait, ModifyLeverParams, IncreaseLeverParams,
        DecreaseLeverParams, ModifyLeverAction
    };
    use vesu_periphery::swap::{RouteNode, TokenAmount, Swap};

    use vesu_periphery_tests::singleton_mock::{ISingletonMockDispatcher, ISingletonMockDispatcherTrait};

    const MIN_SQRT_RATIO_LIMIT: u256 = 18446748437148339061;
    const MAX_SQRT_RATIO_LIMIT: u256 = 6277100250585753475930931601400621808602321654880405518632;

    struct TestConfig {
        ekubo: ContractAddress,
        singleton: ISingletonMockDispatcher,
        multiply: IMultiplyDispatcher,
        pool_id: felt252,
        pool_key: PoolKey,
        eth: IERC20Dispatcher,
        usdc: IERC20Dispatcher,
        user: ContractAddress,
        fee_owner: ContractAddress
    }

    fn deploy_assets(recipient: ContractAddress) -> (IERC20Dispatcher, IERC20Dispatcher) {
        let class = declare("MockAsset");
    
        let decimals = 18;
        let supply = 100 * pow_10(decimals);
        let calldata = array![
            'Collateral', 'COLL', decimals.into(), supply.low.into(), supply.high.into(), recipient.into()
        ];
        let collateral_asset = IERC20Dispatcher { contract_address: class.deploy(@calldata).unwrap() };
    
        let decimals = 18;
        let supply = 100 * pow_10(decimals);
        let calldata = array!['Debt', 'DEBT', decimals.into(), supply.low.into(), supply.high.into(), recipient.into()];
        let debt_asset = IERC20Dispatcher { contract_address: class.deploy(@calldata).unwrap() };
    
        (collateral_asset, debt_asset)
    }

    fn setup(fee_rate: u128) -> TestConfig {
        let fee_owner = contract_address_const::<0x1>();

        let ekubo = deploy_with_args("EkuboMock", array![]);
        let singleton = ISingletonMockDispatcher { contract_address: deploy_with_args("SingletonMock", array![]) };

        let constructor_args: Array<felt252> = array![
            ekubo.into(),
            singleton.contract_address.into(),
            fee_owner.into(),
            fee_rate.into()
        ];

        let multiply = IMultiplyDispatcher {
            contract_address: deploy_with_args("Multiply", constructor_args)
        };

        let (eth, usdc) = deploy_assets(get_contract_address());

        let pool_key = PoolKey {
            token0: eth.contract_address,
            token1: usdc.contract_address,
            fee: 0,
            tick_spacing: 0,
            extension: contract_address_const::<0x0>()
        };

        let user = get_contract_address();

        let pool_id = 0;

        let test_config = TestConfig {
            fee_owner,
            ekubo,
            singleton,
            multiply,
            pool_id,
            pool_key,
            eth,
            usdc,
            user
        };

        test_config
    }

    #[test]
    #[available_gas(20000000)]
    fn test_modify_lever_exact_collateral_deposit_fuzz() {
        let TestConfig { singleton, multiply, pool_id, pool_key, eth, usdc, user, .. } = setup(0);

        let usdc_balance_before = usdc.balanceOf(user);

        usdc.approve(multiply.contract_address, 10000 * SCALE);

        let increase_lever_params = IncreaseLeverParams {
            pool_id,
            collateral_asset: usdc.contract_address,
            debt_asset: eth.contract_address,
            user,
            add_margin: 10000 * SCALE_128,
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
                        amount: i129_new((110 * SCALE_128).try_into().unwrap(), true)
                    }
                }
            ],
            lever_swap_limit_amount: 110 * SCALE_128,
        };

        let modify_lever_params = ModifyLeverParams {
            action: ModifyLeverAction::IncreaseLever(increase_lever_params.clone())
        };

        multiply.modify_lever(modify_lever_params);

        let position = singleton
            .position(pool_id, usdc.contract_address, eth.contract_address, user);

        let y: @Swap = (increase_lever_params.lever_swap[0]);
        let x: u256 = (*y.token_amount.amount.mag).into();
        assert!(position.collateral_shares + 1 == increase_lever_params.add_margin.into() + x);

        assert!(
            usdc.balanceOf(user) == usdc_balance_before - increase_lever_params.add_margin.into()
        );
    }
}


