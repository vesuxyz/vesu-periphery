use starknet::{account::Call, ContractAddress};
use vesu::{common::{i257, i257_new}, data_model::{Amount, UpdatePositionResponse}};
use vesu_periphery::{
    swap::Swap,
    multiply::{
        IMultiplyDispatcher, IMultiplyDispatcherTrait, ModifyLeverParams, ModifyLeverResponse
    },
    vault::{Claim}
};

#[starknet::interface]
pub trait IStrategy<TContractState> {
    fn set_manager(ref self: TContractState, manager: ContractAddress);
    fn claim_rewards(
        ref self: TContractState,
        rewards_contract: ContractAddress,
        claim: Claim,
        proof: Span<felt252>
    );
    fn allocate(ref self: TContractState, swap: Array<Swap>, limit_amount: u128);
}

#[starknet::contract]
pub mod Strategy {
    use core::integer::BoundedInt;

    use starknet::{
        account::Call, syscalls::call_contract_syscall, ContractAddress, get_caller_address,
        get_contract_address, get_block_timestamp
    };
    use ekubo::{
        components::{shared_locker::{consume_callback_data, handle_delta, call_core_with_callback}},
        interfaces::core::{ICoreDispatcher, ICoreDispatcherTrait, ILocker, SwapParameters}
    };
    use vesu::{
        data_model::{
            ModifyPositionParams, Amount, AmountType, AmountDenomination, AssetConfig,
            UpdatePositionResponse
        },
        units::SCALE, singleton::{Singleton, ISingletonDispatcher, ISingletonDispatcherTrait},
        v_token::{IVToken, IVTokenDispatcher, IVTokenDispatcherTrait},
        vendor::{
            erc20::{ERC20ABIDispatcher as IERC20Dispatcher, ERC20ABIDispatcherTrait},
            erc20_component::ERC20Component
        },
        common::{i257, i257_new}
    };
    use vesu_periphery::{
        vault::{IVault, IVaultDispatcher, IVaultDispatcherTrait, Claim},
        strategy::{IStrategy, IStrategyDispatcher, IStrategyDispatcherTrait}, swap::Swap,
    };

    #[storage]
    struct Storage {
        // The vault contract address
        vault: IVaultDispatcher,
        // The manager contract address
        manager: ContractAddress,
        // Reentrancy protection
        lock: bool,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {}

    #[constructor]
    fn constructor(ref self: ContractState, vault: ContractAddress, manager: ContractAddress) {
        self.vault.write(IVaultDispatcher { contract_address: vault });
        self.manager.write(manager);
    }

    #[generate_trait]
    impl InternalFunctions of InternalFunctionsTrait {
        fn assert_manager(ref self: ContractState) {
            assert!(get_caller_address() == self.manager.read(), "caller-not-manager");
        }
    }

    #[abi(embed_v0)]
    impl StrategyImpl of IStrategy<ContractState> {
        fn set_manager(ref self: ContractState, manager: ContractAddress) {
            self.assert_manager();
            self.manager.write(manager);
        }

        fn claim_rewards(
            ref self: ContractState,
            rewards_contract: ContractAddress,
            claim: Claim,
            proof: Span<felt252>
        ) {
            self.assert_manager();
            self.vault.read().claim_rewards(rewards_contract, claim, proof);
        }

        fn allocate(ref self: ContractState, swap: Array<Swap>, limit_amount: u128) {
            self.assert_manager();

            assert!(!self.lock.read(), "reentrancy-lock");
            self.lock.write(true);
            // 
            self.lock.write(false);
        }
    }
}

