use starknet::ContractAddress;
use vesu::common::{i257, i257_new};
use vesu_periphery::swap::{Swap};

#[starknet::interface]
pub trait I4626<TContractState> {
    fn asset(ref self: TContractState) -> ContractAddress;
    fn deposit(ref self: TContractState, assets: u256, recipient: ContractAddress) -> u256;
}

#[derive(Serde, Drop, Clone)]
pub enum ModifyLeverAction {
    IncreaseLever: IncreaseLeverParams
}

#[derive(Serde, Drop, Clone)]
pub struct ModifyLeverParams {
    pub action: ModifyLeverAction
}

#[derive(Serde, Drop, Clone)]
pub struct ModifyLeverResponse {
    pub collateral_delta: i257,
    pub debt_delta: i257,
    pub margin_delta: i257
}

#[derive(Serde, Drop, Clone)]
pub struct IncreaseLeverParams {
    pub pool_id: felt252,
    pub collateral_asset: ContractAddress,
    pub user: ContractAddress,
    pub add_margin: u128,
    pub add_margin_is_wrapped: bool,
    pub lever_amount: u128,
    pub margin_swap: Array<Swap>,
    pub margin_swap_limit_amount: u128,
}

#[starknet::interface]
pub trait IMultiply4626<TContractState> {
    fn modify_lever(
        ref self: TContractState, modify_lever_params: ModifyLeverParams
    ) -> ModifyLeverResponse;
}

#[starknet::contract]
pub mod Multiply4626 {
    use starknet::{ContractAddress, get_contract_address, get_caller_address};

    use ekubo::{
        components::{shared_locker::{consume_callback_data, handle_delta, call_core_with_callback}},
        interfaces::{
            core::{ICoreDispatcher, ICoreDispatcherTrait, ILocker, SwapParameters},
            erc20::{IERC20Dispatcher, IERC20DispatcherTrait}
        },
        types::{i129::{i129, i129Trait, i129_new}, delta::{Delta}, keys::{PoolKey}}
    };

    use vesu::{
        singleton::{ISingleton, ISingletonDispatcher, ISingletonDispatcherTrait},
        data_model::{
            ModifyPositionParams, Amount, AmountType, AmountDenomination, UpdatePositionResponse
        },
        common::{i257, i257_new}, units::{SCALE, SCALE_128}
    };

    use vesu_periphery::swap::{
        Swap, TokenAmount, RouteNode, swap, apply_weights, assert_empty_token_amounts,
        assert_matching_token_amounts
    };

    use super::{
        IMultiply4626, ModifyLeverParams, ModifyLeverAction, IncreaseLeverParams,
        ModifyLeverResponse, I4626Dispatcher, I4626DispatcherTrait
    };

    #[storage]
    struct Storage {
        core: ICoreDispatcher,
        singleton: ISingletonDispatcher
    }

    #[derive(Drop, starknet::Event)]
    struct IncreaseLever {
        #[key]
        pool_id: felt252,
        #[key]
        collateral_asset: ContractAddress,
        #[key]
        debt_asset: ContractAddress,
        #[key]
        user: ContractAddress,
        margin: u256,
        collateral_delta: u256,
        debt_delta: u256
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        IncreaseLever: IncreaseLever
    }

    #[constructor]
    fn constructor(
        ref self: ContractState, core: ICoreDispatcher, singleton: ISingletonDispatcher
    ) {
        self.core.write(core);
        self.singleton.write(singleton);
    }

    #[generate_trait]
    impl InternalFunctions of InternalFunctionsTrait {
        fn increase_lever(
            ref self: ContractState, increase_lever_params: IncreaseLeverParams
        ) -> ModifyLeverResponse {
            let core = self.core.read();

            let IncreaseLeverParams { pool_id,
            collateral_asset,
            user,
            add_margin,
            add_margin_is_wrapped,
            margin_swap,
            margin_swap_limit_amount,
            lever_amount } =
                increase_lever_params;

            let debt_asset = I4626Dispatcher { contract_address: collateral_asset }.asset();

            // - swap margin asset to debt asset (1.)
            let margin_amount = if margin_swap.len() != 0 {
                let (margin_amount_, debt_amount_) = swap(
                    core, margin_swap.clone(), margin_swap_limit_amount
                );
                assert!(
                    add_margin == 0 && debt_amount_.token == debt_asset,
                    "invalid-margin-swap-assets"
                );

                // - transfer margin to multiplier
                assert!(
                    IERC20Dispatcher { contract_address: margin_amount_.token }
                        .transferFrom(
                            user, get_contract_address(), margin_amount_.amount.mag.into()
                        ),
                    "transfer-from-failed"
                );

                // - handleDelta for both (1.)
                handle_delta(
                    core,
                    margin_amount_.token,
                    i129_new(margin_amount_.amount.mag, false),
                    get_contract_address()
                );
                handle_delta(
                    core,
                    debt_asset,
                    i129_new(debt_amount_.amount.mag, true),
                    get_contract_address()
                );

                debt_amount_.amount.mag
            } else {
                // - transfer margin to multiplier
                assert!(
                    IERC20Dispatcher {
                        contract_address: if (add_margin_is_wrapped) {
                            collateral_asset
                        } else {
                            debt_asset
                        }
                    }
                        .transferFrom(user, get_contract_address(), add_margin.into()),
                    "transfer-failed"
                );

                add_margin
            };

            // flashloan lever_amount
            handle_delta(core, debt_asset, i129_new(lever_amount, true), get_contract_address());

            IERC20Dispatcher { contract_address: debt_asset }
                .approve(collateral_asset, (margin_amount + lever_amount).into());

            // exclude margin_amount if margin token is already the wrapped token
            let mut wrapped_amount = I4626Dispatcher { contract_address: collateral_asset }
                .deposit(
                    if add_margin_is_wrapped {
                        lever_amount.into()
                    } else {
                        (margin_amount + lever_amount).into()
                    },
                    get_contract_address()
                );

            if add_margin_is_wrapped {
                wrapped_amount += margin_amount.into();
            }

            let singleton = self.singleton.read();

            assert!(
                IERC20Dispatcher { contract_address: collateral_asset }
                    .approve(singleton.contract_address, wrapped_amount.into()),
                "approve-failed"
            );

            // - deposit collateral asset and draw borrow asset
            let UpdatePositionResponse { collateral_delta, debt_delta, .. } = singleton
                .modify_position(
                    ModifyPositionParams {
                        pool_id,
                        collateral_asset,
                        debt_asset,
                        user,
                        collateral: Amount {
                            amount_type: AmountType::Delta,
                            denomination: AmountDenomination::Assets,
                            value: i257_new(wrapped_amount.into(), false)
                        },
                        debt: Amount {
                            amount_type: AmountType::Delta,
                            denomination: AmountDenomination::Assets,
                            value: i257_new(lever_amount.into(), false)
                        },
                        data: ArrayTrait::new().span()
                    }
                );

            assert!(lever_amount.into() == debt_delta.abs, "invalid-debt-delta");

            handle_delta(core, debt_asset, i129_new(lever_amount, false), get_contract_address());

            self
                .emit(
                    IncreaseLever {
                        pool_id,
                        collateral_asset,
                        debt_asset,
                        user,
                        margin: margin_amount.into(),
                        collateral_delta: collateral_delta.abs,
                        debt_delta: debt_delta.abs
                    }
                );

            return ModifyLeverResponse {
                collateral_delta: collateral_delta,
                debt_delta: debt_delta,
                margin_delta: i257_new(margin_amount.into(), false)
            };
        }
    }

    #[abi(embed_v0)]
    impl LockerImpl of ILocker<ContractState> {
        fn locked(ref self: ContractState, id: u32, mut data: Span<felt252>) -> Span<felt252> {
            let core = self.core.read();

            // asserts that caller is core
            let modify_lever_params: ModifyLeverParams = consume_callback_data(core, data);
            let modify_lever_response = match modify_lever_params.action {
                ModifyLeverAction::IncreaseLever(params) => self.increase_lever(params)
            };

            let mut data: Array<felt252> = array![];
            Serde::serialize(@modify_lever_response, ref data);
            data.span()
        }
    }

    #[abi(embed_v0)]
    impl Multiply4626Impl of IMultiply4626<ContractState> {
        fn modify_lever(
            ref self: ContractState, modify_lever_params: ModifyLeverParams
        ) -> ModifyLeverResponse {
            let user = match modify_lever_params.clone().action {
                ModifyLeverAction::IncreaseLever(params) => params.user
            };
            assert!(user == get_caller_address(), "caller-not-user");
            call_core_with_callback(self.core.read(), @modify_lever_params)
        }
    }
}
