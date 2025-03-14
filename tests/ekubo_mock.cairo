
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
        rate: u128
    );

    fn swap(
        ref self: TContractState, pool_key: PoolKey, swap_params: SwapParameters
    ) -> Delta;
}

#[starknet::contract]
pub mod EkuboMock {
    use starknet::{ContractAddress};

    use ekubo::{
        interfaces::core::{SwapParameters},
        types::{i129::{i129, i129Trait, i129_new}, keys::{PoolKey}, delta::{Delta}}
    };

    use vesu::units::{SCALE_128};

    use super::{IEkuboMock};

    #[storage]
    struct Storage {
        rate: LegacyMap<(ContractAddress, ContractAddress), u128>
    }

    #[abi(embed_v0)]
    impl EkuboMockImpl of IEkuboMock<ContractState> {
        fn set_rate(
            ref self: ContractState,
            pool_key: PoolKey,
            rate: u128
        ) {
            self.rate.write((pool_key.token0, pool_key.token1), rate);
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
                    amount1 = i129_new(amount * rate / SCALE_128, true);
                } else {
                    amount0 = i129_new(amount * SCALE_128 / rate, true);
                    amount1 = i129_new(amount, false);
                }
            } else {
                if swap_params.is_token1 {
                    amount0 = i129_new(amount * SCALE_128 / rate, true);
                    amount1 = i129_new(amount, false);
                } else {
                    amount0 = i129_new(amount, false);
                    amount1 = i129_new(amount * rate / SCALE_128, true);
                }
            }

            Delta { amount0, amount1 }
        }
    }
}
