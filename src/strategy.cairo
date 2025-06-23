// use starknet::{account::Call, ContractAddress};
// use vesu::{common::{i257, i257_new}, data_model::{Amount, UpdatePositionResponse}};
// use vesu_periphery::{
//     swap::Swap,
//     multiply::{
//         IMultiplyDispatcher, IMultiplyDispatcherTrait, ModifyLeverParams, ModifyLeverResponse
//     }
// };

// #[starknet::interface]
// pub trait IStrategy<TContractState> {
//     fn set_manager(ref self: TContractState, manager: ContractAddress);
//     fn pool_info(self: @TContractState) -> (felt252, ContractAddress, ContractAddress);
//     fn set_pool_info(
//         ref self: TContractState, pool_info: (felt252, ContractAddress, ContractAddress)
//     );
//     fn nav(self: @TContractState) -> u256;
//     fn wind(ref self: TContractState, assets: u256) -> u256;
//     fn unwind(ref self: TContractState, assets: u256) -> u256;
// }

// #[starknet::contract]
// pub mod Strategy {
//     use core::integer::BoundedInt;

//     use starknet::{
//         account::Call, syscalls::call_contract_syscall, ContractAddress, get_caller_address,
//         get_contract_address
//     };
//     use ekubo::{
//         components::{shared_locker::{consume_callback_data, handle_delta, call_core_with_callback}},
//         interfaces::core::{ICoreDispatcher, ICoreDispatcherTrait, ILocker, SwapParameters}
//     };
//     use vesu::{
//         data_model::{
//             ModifyPositionParams, Amount, AmountType, AmountDenomination, AssetConfig,
//             UpdatePositionResponse
//         },
//         units::SCALE, singleton::{Singleton, ISingletonDispatcher, ISingletonDispatcherTrait},
//         v_token::{IVToken, IVTokenDispatcher, IVTokenDispatcherTrait},
//         vendor::{
//             erc20::{ERC20ABIDispatcher as IERC20Dispatcher, ERC20ABIDispatcherTrait},
//             erc20_component::ERC20Component
//         },
//         common::{i257, i257_new}
//     };
//     use vesu_periphery::{
//         vault::{IVault, IVaultDispatcher, IVaultDispatcherTrait},
//         strategy::{IStrategy, IStrategyDispatcher, IStrategyDispatcherTrait}
//     };

//     #[storage]
//     struct Storage {
//         // The vault contract address
//         vault: IVaultDispatcher,
//         // The manager contract address
//         manager: ContractAddress,
//         // The pool info
//         pool_info: (felt252, ContractAddress, ContractAddress),

//     }

//     #[event]
//     #[derive(Drop, starknet::Event)]
//     enum Event {}

//     #[constructor]
//     fn constructor(ref self: ContractState, vault: ContractAddress, manager: ContractAddress) {
//         self.vault.write(IVaultDispatcher { contract_address: vault });
//         self.manager.write(manager);
//     }

//     #[generate_trait]
//     impl InternalFunctions of InternalFunctionsTrait {}

//     #[abi(embed_v0)]
//     impl StrategyImpl of IStrategy<ContractState> {
//         fn set_manager(ref self: ContractState, manager: ContractAddress) {
//             assert!(get_caller_address() == self.manager.read(), "caller-not-manager");
//             self.manager.write(manager);
//         }

//         fn pool_info(self: @ContractState) -> (felt252, ContractAddress, ContractAddress) {
//             self.pool_info.read()
//         }

//         fn set_pool_info(
//             ref self: ContractState, pool_info: (felt252, ContractAddress, ContractAddress)
//         ) {
//             assert!(get_caller_address() == self.manager.read(), "caller-not-manager");
//             self.pool_info.write(pool_info);
//         }

//         fn sync(ref self: ContractState) {// reentrancy protection            
//         }
//     }
// }


