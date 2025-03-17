#[cfg(test)]
mod Test_896150_Multiply_FUZZ {
    use snforge_std::{
        start_prank, stop_prank, start_warp, stop_warp, CheatTarget, load, declare, ContractClass,
        ContractClassTrait
    };
    use starknet::{
        ContractAddress, contract_address_const, get_block_timestamp, get_caller_address,
        get_contract_address
    };
    use core::num::traits::{Zero};
    use core::integer::{BoundedInt};
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
        common::{i257, i257_new}, math::{pow_10},
    };
    use vesu_periphery::multiply::{
        IMultiplyDispatcher, IMultiplyDispatcherTrait, ModifyLeverParams, IncreaseLeverParams,
        DecreaseLeverParams, ModifyLeverAction
    };
    use vesu_periphery::swap::{RouteNode, TokenAmount, Swap};

    use vesu_periphery::test::singleton_mock::{
        ISingletonMockDispatcher, ISingletonMockDispatcherTrait
    };
    use vesu_periphery::test::ekubo_mock::{IEkuboMockDispatcher, IEkuboMockDispatcherTrait};

    const MIN_SQRT_RATIO_LIMIT: u256 = 18446748437148339061;
    const MAX_SQRT_RATIO_LIMIT: u256 = 6277100250585753475930931601400621808602321654880405518632;

    struct TestConfig {
        ekubo: IEkuboMockDispatcher,
        singleton: ISingletonMockDispatcher,
        multiply: IMultiplyDispatcher,
        pool_id: felt252,
        pool_key: PoolKey,
        eth: IERC20Dispatcher,
        usdc: IERC20Dispatcher,
        user: ContractAddress,
        fee_owner: ContractAddress
    }

    fn scale(x: u256, x_min: u256, x_max: u256, min: u256, max: u256) -> u256 {
        min + ((x - x_min) * (max - min)) / (x_max - x_min)
    }

    fn deploy_assets(recipient: ContractAddress) -> (IERC20Dispatcher, IERC20Dispatcher) {
        let class = declare("MockAsset");

        let decimals = 18;
        let supply = 5_000_000_000 * pow_10(decimals);
        let calldata = array![
            'Collateral',
            'COLL',
            decimals.into(),
            supply.low.into(),
            supply.high.into(),
            recipient.into()
        ];
        let collateral_asset = IERC20Dispatcher {
            contract_address: class.deploy(@calldata).unwrap()
        };

        let decimals = 18;
        let supply = 5_000_000_000 * pow_10(decimals);
        let calldata = array![
            'Debt', 'DEBT', decimals.into(), supply.low.into(), supply.high.into(), recipient.into()
        ];
        let debt_asset = IERC20Dispatcher { contract_address: class.deploy(@calldata).unwrap() };

        (collateral_asset, debt_asset)
    }

    fn setup(fee_rate: u128) -> TestConfig {
        let fee_owner = contract_address_const::<0x1>();

        let ekubo = IEkuboMockDispatcher {
            contract_address: deploy_with_args("EkuboMock", array![])
        };
        let singleton = ISingletonMockDispatcher {
            contract_address: deploy_with_args("SingletonMock", array![])
        };

        let constructor_args: Array<felt252> = array![
            ekubo.contract_address.into(),
            singleton.contract_address.into(),
            fee_owner.into(),
            fee_rate.into()
        ];

        let multiply = IMultiplyDispatcher {
            contract_address: deploy_with_args("Multiply", constructor_args)
        };

        let (eth, usdc) = deploy_assets(get_contract_address());

        usdc.transfer(ekubo.contract_address, 1_000_000_000 * SCALE);
        eth.transfer(ekubo.contract_address, 1_000_000_000 * SCALE);

        usdc.transfer(singleton.contract_address, 1_000_000_000 * SCALE);
        eth.transfer(singleton.contract_address, 1_000_000_000 * SCALE);

        let pool_key = PoolKey {
            token0: eth.contract_address,
            token1: usdc.contract_address,
            fee: 0,
            tick_spacing: 0,
            extension: contract_address_const::<0x0>()
        };

        ekubo.set_rate(pool_key, SCALE);

        let user = get_contract_address();

        let pool_id = 0;

        let test_config = TestConfig {
            fee_owner, ekubo, singleton, multiply, pool_id, pool_key, eth, usdc, user
        };

        test_config
    }

    #[test]
    #[available_gas(20000000)]
    fn test_modify_lever_exact_collateral_deposit_with_fee_fuzz(a: u128, b: u128, c: u128) {
        let max: u128 = BoundedInt::max();
        let fee_rate: u256 = scale(a.into(), 0, max.into(), 0, SCALE);
        let margin_amount = scale(b.into(), 0, max.into(), 0, 1_000_000_000 * SCALE)
            .try_into()
            .unwrap();
        let lever_amount = scale(c.into(), 0, max.into(), 1, 1_000_000_000 * SCALE)
            .try_into()
            .unwrap();

        let TestConfig { singleton, multiply, pool_id, pool_key, eth, usdc, user, .. } = setup(
            fee_rate.try_into().unwrap()
        );

        let usdc_balance_before = usdc.balanceOf(user);

        usdc.approve(multiply.contract_address, margin_amount.into());

        let increase_lever_params = IncreaseLeverParams {
            pool_id,
            collateral_asset: usdc.contract_address,
            debt_asset: eth.contract_address,
            user,
            add_margin: margin_amount,
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
                        amount: i129_new((lever_amount).try_into().unwrap(), true)
                    }
                }
            ],
            lever_swap_limit_amount: lever_amount,
        };

        let modify_lever_params = ModifyLeverParams {
            action: ModifyLeverAction::IncreaseLever(increase_lever_params.clone())
        };

        multiply.modify_lever(modify_lever_params);

        let (position, _, _) = singleton
            .position(pool_id, usdc.contract_address, eth.contract_address, user);

        let y: @Swap = (increase_lever_params.lever_swap[0]);
        let x: u256 = (*y.token_amount.amount.mag).into();
        assert!(
            position.collateral_shares == increase_lever_params.add_margin.into()
                + x
                - (fee_rate * x / SCALE)
        );

        assert!(
            usdc.balanceOf(user) == usdc_balance_before - increase_lever_params.add_margin.into()
        );
    }

    #[test]
    #[available_gas(20000000)]
    fn test_modify_lever_close_with_fee_fuzz(a: u128, b: u128, c: u128) {
        let max: u128 = BoundedInt::max();
        let fee_rate: u256 = scale(a.into(), 0, max.into(), 0, SCALE);
        let margin_amount: u128 = scale(b.into(), 0, max.into(), 0, 1_000_000_000 * SCALE)
            .try_into()
            .unwrap();
        let lever_amount = scale(c.into(), 0, max.into(), 1, 1_000_000_000 * SCALE)
            .try_into()
            .unwrap();

        let TestConfig { singleton, multiply, pool_id, pool_key, eth, usdc, user, .. } = setup(
            fee_rate.try_into().unwrap()
        );

        let user_balance_before = usdc.balanceOf(user);

        usdc
            .approve(
                multiply.contract_address,
                margin_amount.into() + (fee_rate * lever_amount.into() / SCALE) * 2
            );

        let increase_lever_params = IncreaseLeverParams {
            pool_id,
            collateral_asset: usdc.contract_address,
            debt_asset: eth.contract_address,
            user,
            add_margin: margin_amount
                + (fee_rate * lever_amount.into() / SCALE).try_into().unwrap() * 2,
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
                        amount: i129_new(lever_amount.try_into().unwrap(), true)
                    }
                }
            ],
            lever_swap_limit_amount: lever_amount,
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
            lever_swap_limit_amount: lever_amount
                + (fee_rate * lever_amount.into() / SCALE).try_into().unwrap(),
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

        let (position, collateral, debt) = singleton
            .position(pool_id, usdc.contract_address, eth.contract_address, user);
        assert!(position.collateral_shares == 0);
        assert!(position.nominal_debt == 0);
        assert!(collateral == 0);
        assert!(debt == 0);

        assert!(
            usdc.balanceOf(user) >= user_balance_before
                - (fee_rate * lever_amount.into() / SCALE) * 2
        );
    }
}

