use starknet::{ContractAddress};
use vesu::common::{i257, i257_new};
use vesu_periphery::swap::{Swap};

#[derive(Serde, Drop, Clone)]
pub enum ModifyLeverAction {
    IncreaseLever: IncreaseLeverParams,
    DecreaseLever: DecreaseLeverParams
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
    pub debt_asset: ContractAddress,
    pub user: ContractAddress,
    pub add_margin: u128,
    pub margin_swap: Array<Swap>,
    pub margin_swap_limit_amount: u128,
    pub lever_swap: Array<Swap>,
    pub lever_swap_limit_amount: u128
}

#[derive(Serde, Drop, Clone)]
pub struct DecreaseLeverParams {
    pub pool_id: felt252,
    pub collateral_asset: ContractAddress,
    pub debt_asset: ContractAddress,
    pub user: ContractAddress,
    pub sub_margin: u128,
    pub recipient: ContractAddress,
    pub lever_swap: Array<Swap>,
    pub lever_swap_limit_amount: u128,
    pub lever_swap_weights: Array<u128>,
    pub withdraw_swap: Array<Swap>,
    pub withdraw_swap_limit_amount: u128,
    pub withdraw_swap_weights: Array<u128>,
    pub close_position: bool
}

#[starknet::interface]
pub trait IMultiply<TContractState> {
    fn set_fee_owner(ref self: TContractState, fee_owner: ContractAddress);
    fn fee_owner(self: @TContractState) -> ContractAddress;
    fn fee_rate(self: @TContractState) -> u128;
    fn modify_lever(
        ref self: TContractState, modify_lever_params: ModifyLeverParams
    ) -> ModifyLeverResponse;
}

#[starknet::contract]
pub mod Multiply {
    use starknet::{ContractAddress, get_contract_address, get_caller_address};

    use core::num::traits::{Zero};

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
        IMultiply, ModifyLeverParams, ModifyLeverAction, IncreaseLeverParams, DecreaseLeverParams,
        ModifyLeverResponse
    };

    #[storage]
    struct Storage {
        core: ICoreDispatcher,
        singleton: ISingletonDispatcher,
        fee_owner: ContractAddress,
        fee_rate: u128
    }

    #[derive(Drop, starknet::Event)]
    struct SetOwner {
        fee_owner: ContractAddress
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

    #[derive(Drop, starknet::Event)]
    struct DecreaseLever {
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
        SetOwner: SetOwner,
        IncreaseLever: IncreaseLever,
        DecreaseLever: DecreaseLever
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        core: ICoreDispatcher,
        singleton: ISingletonDispatcher,
        fee_owner: ContractAddress,
        fee_rate: u128
    ) {
        self.core.write(core);
        self.singleton.write(singleton);
        self.fee_owner.write(fee_owner);
        self.fee_rate.write(fee_rate);
    }

    #[generate_trait]
    impl InternalFunctions of InternalFunctionsTrait {
        fn increase_lever(
            ref self: ContractState, increase_lever_params: IncreaseLeverParams
        ) -> ModifyLeverResponse {
            let core = self.core.read();

            let IncreaseLeverParams { pool_id,
            collateral_asset,
            debt_asset,
            user,
            add_margin,
            margin_swap,
            margin_swap_limit_amount,
            lever_swap,
            lever_swap_limit_amount } =
                increase_lever_params;

            // - swap margin asset to collateral asset (1.)
            let margin_amount = if margin_swap.len() != 0 {
                let (margin_amount_, collateral_amount_) = swap(
                    core, margin_swap.clone(), margin_swap_limit_amount
                );
                assert!(
                    add_margin == 0 && collateral_amount_.token == collateral_asset,
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
                    collateral_asset,
                    i129_new(collateral_amount_.amount.mag, true),
                    get_contract_address()
                );

                collateral_amount_.amount.mag
            } else {
                // - transfer margin to multiplier
                assert!(
                    IERC20Dispatcher { contract_address: collateral_asset }
                        .transferFrom(user, get_contract_address(), add_margin.into()),
                    "transfer-failed"
                );

                add_margin
            };

            // - swap debt asset to collateral asset (2.)
            // for borrowing an exact amount of debt
            //   - input token: debt asset and output token: collateral asset, since we specify a positive input amount
            //     of the debt asset
            // for depositing an exact amount of collateral:
            //   - input token: collateral asset and output token: debt asset, since we specify a negative input amount
            //     of the collateral asset (swap direction is reversed)
            let (debt_amount, mut collateral_amount) = if lever_swap.len() != 0 {
                swap(core, lever_swap.clone(), lever_swap_limit_amount)
            } else {
                (
                    TokenAmount { token: debt_asset, amount: i129_new(0, true) },
                    TokenAmount { token: collateral_asset, amount: i129_new(0, false) }
                )
            };

            assert!(
                debt_amount.token == debt_asset && collateral_amount.token == collateral_asset,
                "invalid-lever-swap-assets"
            );

            // - handleDelta (2.): withdraw collateral asset
            handle_delta(
                core,
                collateral_amount.token,
                i129_new(collateral_amount.amount.mag, true),
                get_contract_address()
            );

            // charge swap fee on the collateral amount to deposit
            let fee = self.fee_rate.read() * collateral_amount.amount.mag / SCALE_128;
            if fee > 0 {
                assert!(self.fee_owner.read() != Zero::zero(), "zero-fee-recipient");
                collateral_amount.amount.mag -= fee;
                assert!(
                    IERC20Dispatcher { contract_address: collateral_asset }
                        .transfer(self.fee_owner.read(), fee.into()),
                    "transfer-failed"
                );
            }

            let singleton = self.singleton.read();

            assert!(
                IERC20Dispatcher { contract_address: collateral_asset }
                    .approve(
                        singleton.contract_address,
                        (collateral_amount.amount.mag + margin_amount).into()
                    ),
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
                            value: i257_new(
                                (collateral_amount.amount.mag + margin_amount).into(), false
                            )
                        },
                        debt: Amount {
                            amount_type: AmountType::Delta,
                            denomination: AmountDenomination::Assets,
                            value: i257_new(debt_amount.amount.mag.into(), false)
                        },
                        data: ArrayTrait::new().span()
                    }
                );

            // - handleDelta (2.): settle borrow asset
            handle_delta(
                core,
                debt_amount.token,
                i129_new(debt_amount.amount.mag, false),
                get_contract_address()
            );

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

        fn decrease_lever(
            ref self: ContractState, decrease_lever_params: DecreaseLeverParams
        ) -> ModifyLeverResponse {
            let DecreaseLeverParams { pool_id,
            collateral_asset,
            debt_asset,
            user,
            mut sub_margin,
            recipient,
            mut lever_swap,
            lever_swap_limit_amount,
            lever_swap_weights,
            mut withdraw_swap,
            withdraw_swap_limit_amount,
            withdraw_swap_weights,
            close_position } =
                decrease_lever_params;

            let core = self.core.read();

            // fee is either added to the swap output amount if the position gets closed or simply deducted from the
            // repaid debt amount (less debt is repaid)
            let mut fee: u128 = 0;

            if close_position {
                assert_empty_token_amounts(lever_swap.clone());
                let singleton = self.singleton.read();
                let (_, _, mut debt) = singleton
                    .position(pool_id, collateral_asset, debt_asset, user);
                // apply fee on the total debt since it's equal to the swap output amount
                fee = (debt.try_into().unwrap() * self.fee_rate.read().into()) / SCALE_128;
                // increase the required swap output amount by the fee
                debt = debt + fee.into();
                // apply weights to lever_swap token amounts
                lever_swap =
                    apply_weights(
                        lever_swap, lever_swap_weights, i129_new(debt.try_into().unwrap(), true)
                    );
                assert!(sub_margin == 0, "invalid-sub-margin-for-close-position");
            }

            // - swap collateral asset to debt asset (1.)
            // for withdrawing an exact amount of collateral:
            //   - input token: collateral asset and output token: debt asset, since we specify a positive input amount
            //     of the collateral asset
            // for repaying an exact amount of debt:
            //   - input token: debt asset and output token: collateral asset, since we specify a negative input amount
            //     of the debt asset (swap direction is reversed)
            let (collateral_amount, mut debt_amount) = if lever_swap.len() != 0 {
                swap(core, lever_swap.clone(), lever_swap_limit_amount)
            } else {
                (
                    TokenAmount { token: collateral_asset, amount: i129_new(0, true) },
                    TokenAmount { token: debt_asset, amount: i129_new(0, false) }
                )
            };

            assert!(
                collateral_amount.token == collateral_asset && debt_amount.token == debt_asset,
                "invalid-lever-swap-assets"
            );

            // - handleDelta: withdraw debt asset (1.)
            handle_delta(
                self.core.read(),
                debt_amount.token,
                i129_new(debt_amount.amount.mag, true),
                get_contract_address()
            );

            if !close_position {
                // apply fee on the repaid debt amount since it's equal to the swap output amount
                fee = self.fee_rate.read() * debt_amount.amount.mag / SCALE_128;
            }

            // deduct fee from repaid debt amount
            // (in case of close_position, debt_amount will be reduced to the position's debt)
            debt_amount.amount.mag -= fee;

            if fee > 0 {
                assert!(self.fee_owner.read() != Zero::zero(), "zero-fee-recipient");
                assert!(
                    IERC20Dispatcher { contract_address: debt_asset }
                        .transfer(self.fee_owner.read(), fee.into()),
                    "transfer-failed"
                );
            }

            let singleton = self.singleton.read();

            assert!(
                IERC20Dispatcher { contract_address: debt_asset }
                    .approve(singleton.contract_address, debt_amount.amount.mag.into()),
                "approve-failed"
            );

            // - withdraw collateral asset and repay borrow asset
            let UpdatePositionResponse { collateral_delta, debt_delta, .. } = self
                .singleton
                .read()
                .modify_position(
                    ModifyPositionParams {
                        pool_id,
                        collateral_asset,
                        debt_asset,
                        user,
                        collateral: if close_position {
                            Amount {
                                amount_type: AmountType::Target,
                                denomination: AmountDenomination::Native,
                                value: i257_new(0, false)
                            }
                        } else {
                            Amount {
                                amount_type: AmountType::Delta,
                                denomination: AmountDenomination::Assets,
                                value: i257_new(
                                    (collateral_amount.amount.mag + sub_margin).into(), true
                                )
                            }
                        },
                        debt: if close_position {
                            Amount {
                                amount_type: AmountType::Target,
                                denomination: AmountDenomination::Native,
                                value: i257_new(0, false)
                            }
                        } else {
                            Amount {
                                amount_type: AmountType::Delta,
                                denomination: AmountDenomination::Assets,
                                value: i257_new(debt_amount.amount.mag.into(), true)
                            }
                        },
                        data: ArrayTrait::new().span()
                    }
                );

            assert!(debt_amount.amount.mag.into() == debt_delta.abs, "excess-debt-repayment");

            // - handleDelta: settle collateral asset (1.)
            handle_delta(
                self.core.read(),
                collateral_amount.token,
                i129_new(collateral_amount.amount.mag, false),
                get_contract_address()
            );

            let residual_collateral = collateral_delta.abs.try_into().unwrap()
                - collateral_amount.amount.mag;

            self
                .emit(
                    DecreaseLever {
                        pool_id,
                        collateral_asset,
                        debt_asset,
                        user,
                        margin: sub_margin.into(),
                        collateral_delta: collateral_delta.abs,
                        debt_delta: debt_delta.abs
                    }
                );

            // avoid withdraw_swap moving error by returning early here
            if withdraw_swap.len() == 0 {
                assert!(
                    IERC20Dispatcher { contract_address: collateral_asset }
                        .transfer(recipient, residual_collateral.into()),
                    "transfer-failed"
                );
                return ModifyLeverResponse {
                    collateral_delta: collateral_delta,
                    debt_delta: debt_delta,
                    margin_delta: i257_new(residual_collateral.into(), true)
                };
            }

            // - swap residual / margin collateral amount to arbitrary asset and handle delta
            assert_empty_token_amounts(withdraw_swap.clone());

            // apply weights to withdraw_swap token amounts
            withdraw_swap =
                apply_weights(
                    withdraw_swap, withdraw_swap_weights, i129_new(residual_collateral, true)
                );

            // collateral_asset to arbitrary_asset
            // token_amount is always positive, limit_amount is min. amount out:
            let (collateral_margin_amount, out_amount) = swap(
                core, withdraw_swap.clone(), withdraw_swap_limit_amount
            );

            handle_delta(
                self.core.read(),
                collateral_margin_amount.token,
                i129_new(collateral_margin_amount.amount.mag, false),
                get_contract_address()
            );
            handle_delta(
                self.core.read(), out_amount.token, i129_new(out_amount.amount.mag, true), recipient
            );

            return ModifyLeverResponse {
                collateral_delta: collateral_delta,
                debt_delta: debt_delta,
                margin_delta: i257_new(out_amount.amount.mag.into(), true)
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
                ModifyLeverAction::IncreaseLever(params) => self.increase_lever(params),
                ModifyLeverAction::DecreaseLever(params) => self.decrease_lever(params)
            };

            let mut data: Array<felt252> = array![];
            Serde::serialize(@modify_lever_response, ref data);
            data.span()
        }
    }

    #[abi(embed_v0)]
    impl MultiplyImpl of IMultiply<ContractState> {
        fn set_fee_owner(ref self: ContractState, fee_owner: ContractAddress) {
            assert!(get_caller_address() == self.fee_owner.read(), "caller-not-fee_owner");
            self.fee_owner.write(fee_owner);
            self.emit(SetOwner { fee_owner });
        }

        fn fee_owner(self: @ContractState) -> ContractAddress {
            self.fee_owner.read()
        }

        fn fee_rate(self: @ContractState) -> u128 {
            self.fee_rate.read()
        }

        fn modify_lever(
            ref self: ContractState, modify_lever_params: ModifyLeverParams
        ) -> ModifyLeverResponse {
            let user = match modify_lever_params.clone().action {
                ModifyLeverAction::IncreaseLever(params) => params.user,
                ModifyLeverAction::DecreaseLever(params) => params.user
            };
            assert!(user == get_caller_address(), "caller-not-user");
            call_core_with_callback(self.core.read(), @modify_lever_params)
        }
    }
}
