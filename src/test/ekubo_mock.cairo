
use starknet::{ContractAddress};

use ekubo::{
    interfaces::core::{SwapParameters},
    types::{keys::{PoolKey}, delta::{Delta}}
};

#[starknet::interface]
pub trait IEkuboMock<TContractState> {
    fn set_rate(
        ref self: TContractState,
        pool_key: PoolKey,
        rate: u256
    );

    fn lock(ref self: TContractState, data: Span<felt252>) -> Span<felt252>;

    fn withdraw(
        ref self: TContractState, token_address: ContractAddress, recipient: ContractAddress, amount: u128
    );

    fn pay(ref self: TContractState, token_address: ContractAddress);

    fn swap(
        ref self: TContractState, pool_key: PoolKey, swap_params: SwapParameters
    ) -> Delta;
}

#[starknet::contract]
pub mod EkuboMock {
    use starknet::{ContractAddress, get_caller_address, get_contract_address};

    use core::serde::Serde;

    use ekubo::{
        interfaces::{core::{SwapParameters, ILockerDispatcher, ILockerDispatcherTrait}, erc20::{IERC20Dispatcher, IERC20DispatcherTrait}},
        types::{i129::{i129, i129Trait, i129_new}, keys::{PoolKey}, delta::{Delta}},
        components::util::{serialize}
    };

    use vesu_periphery::multiply::{ModifyLeverResponse};

    use vesu::units::{SCALE};
    use vesu::common::{i257, i257_new};

    use super::{IEkuboMock};

    #[storage]
    struct Storage {
        rate: LegacyMap<(ContractAddress, ContractAddress), u256>
    }

    #[abi(embed_v0)]
    impl EkuboMockImpl of IEkuboMock<ContractState> {
        fn set_rate(
            ref self: ContractState,
            pool_key: PoolKey,
            rate: u256
        ) {
            self.rate.write((pool_key.token0, pool_key.token1), rate);
        }

        fn lock(ref self: ContractState, data: Span<felt252>) -> Span<felt252> {
            let locker = ILockerDispatcher { contract_address: get_caller_address() };
            locker.locked(0, data)
        }

        fn withdraw(
            ref self: ContractState, token_address: ContractAddress, recipient: ContractAddress, amount: u128
        ) {
            let token = IERC20Dispatcher { contract_address: token_address };
            token.transfer(recipient, amount.into());
        }

        fn pay(ref self: ContractState, token_address: ContractAddress) {
            let token = IERC20Dispatcher { contract_address: token_address };
            let approval = token.allowance(get_caller_address(), get_contract_address());
            token.transferFrom(get_caller_address(), get_contract_address(), approval);
        }

        fn swap(
            ref self: ContractState, pool_key: PoolKey, swap_params: SwapParameters
        ) -> Delta {
            let rate = self.rate.read((pool_key.token0, pool_key.token1));

            let mut amount0: i129 = i129_new(0, false);
            let mut amount1: i129 = i129_new(0, false);

            let is_exact_in = !swap_params.amount.is_negative();
            let amount = swap_params.amount.mag;

            if is_exact_in {
                if swap_params.is_token1 {
                    amount0 = i129_new(amount, false);
                    let a: u256 = amount.into() * rate;
                    let b: u256 = a / SCALE;
                    amount1 = i129_new(b.try_into().unwrap(), true);
                } else {
                    let a: u256 = amount.into() * SCALE;
                    let b: u256 = a / rate;
                    amount0 = i129_new(b.try_into().unwrap(), true);
                    amount1 = i129_new(amount, false);
                }
            } else {
                if swap_params.is_token1 {
                    let a: u256 = amount.into() * SCALE;
                    let b: u256 = a / rate;
                    amount0 = i129_new(b.try_into().unwrap(), true);
                    amount1 = i129_new(amount, false);
                } else {
                    amount0 = i129_new(amount, false);
                    let a: u256 = amount.into() * SCALE;
                    let b: u256 = a / rate;
                    amount1 = i129_new(b.try_into().unwrap(), true);
                }
            }

            Delta { amount0, amount1 }
        }
    }
}
