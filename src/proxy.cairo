use starknet::{account::Call, ContractAddress};

#[generate_trait]
impl ArrayExt<T, +Drop<T>, +Copy<T>> of ArrayExtTrait<T> {
    fn append_all(ref self: Array<T>, mut value: Span<T>) {
        while let Option::Some(item) = value.pop_front() {
            self.append(*item);
        };
    }
}

#[starknet::interface]
pub trait IProxy<TContractState> {
    fn set_caller_for_method(ref self: TContractState, contract: ContractAddress, method: felt252);
    fn set_manager(ref self: TContractState, new_manager: ContractAddress);
    fn proxy_call(ref self: TContractState, calls: Span<Call>) -> Array<Span<felt252>>;
}

#[starknet::contract]
pub mod Proxy {
    use starknet::{
        account::Call, syscalls::call_contract_syscall, ContractAddress, get_caller_address
    };
    use vesu::singleton::{Singleton, ISingletonDispatcher, ISingletonDispatcherTrait};
    use super::ArrayExt;
    use super::IProxy;

    #[storage]
    struct Storage {
        singleton: ISingletonDispatcher,
        manager: ContractAddress,
        access_control: LegacyMap<(ContractAddress, felt252), bool>
    }

    #[derive(Drop, starknet::Event)]
    struct SetManager {
        #[key]
        manager: ContractAddress
    }

    #[derive(Drop, starknet::Event)]
    struct SetCallerForSelector {
        #[key]
        caller: ContractAddress,
        #[key]
        selector: felt252,
        can_call: bool
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        SetManager: SetManager,
        SetCallerForSelector: SetCallerForSelector
    }

    #[constructor]
    fn constructor(
        ref self: ContractState, singleton: ISingletonDispatcher, manager: ContractAddress
    ) {
        self.singleton.write(singleton);
        self.manager.write(manager);
        self.emit(SetManager { manager });
    }

    #[abi(embed_v0)]
    impl ProxyImpl of IProxy<ContractState> {
        fn set_caller_for_method(
            ref self: ContractState, contract: ContractAddress, method: felt252
        ) {
            assert!(get_caller_address() == self.manager.read(), "caller-not-manager");
            self.access_control.write((contract, method), true);
            self
                .emit(
                    SetCallerForSelector {
                        caller: get_caller_address(), selector: method, can_call: true
                    }
                );
        }

        fn set_manager(ref self: ContractState, new_manager: ContractAddress) {
            assert!(get_caller_address() == self.manager.read(), "caller-not-manager");
            self.manager.write(new_manager);
            self.emit(SetManager { manager: new_manager });
        }

        fn proxy_call(ref self: ContractState, mut calls: Span<Call>) -> Array<Span<felt252>> {
            let mut result = array![];
            let mut index = 0;
            while let Option::Some(call) = calls
                .pop_front() {
                    assert!(
                        get_caller_address() == self.manager.read()
                            || self.access_control.read((*call.to, *call.selector)),
                        "caller-not-authorized"
                    );

                    match call_contract_syscall(*call.to, *call.selector, *call.calldata) {
                        Result::Ok(retdata) => {
                            result.append(retdata);
                            index += 1;
                        },
                        Result::Err(revert_reason) => {
                            let mut data = array!['proxy-call-failed', index];
                            data.append_all(revert_reason.span());
                            panic(data);
                        },
                    }
                };
            result
        }
    }
}
