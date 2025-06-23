use starknet::{account::Call, ContractAddress};
use vesu::{common::{i257, i257_new}, data_model::{Amount, UpdatePositionResponse}};
use vesu_periphery::{
    swap::Swap,
    multiply::{
        IMultiplyDispatcher, IMultiplyDispatcherTrait, ModifyLeverParams, ModifyLeverResponse
    }
};

#[starknet::interface]
trait IERC4626<TContractState> {
    fn asset(self: @TContractState) -> ContractAddress;
    fn total_assets(self: @TContractState) -> u256;
    fn convert_to_shares(self: @TContractState, assets: u256) -> u256;
    fn convert_to_assets(self: @TContractState, shares: u256) -> u256;
    fn max_deposit(self: @TContractState, receiver: ContractAddress) -> u256;
    fn preview_deposit(self: @TContractState, assets: u256) -> u256;
    fn deposit(ref self: TContractState, assets: u256, receiver: ContractAddress) -> u256;
    fn max_mint(self: @TContractState, receiver: ContractAddress) -> u256;
    fn preview_mint(self: @TContractState, shares: u256) -> u256;
    fn mint(ref self: TContractState, shares: u256, receiver: ContractAddress) -> u256;
    fn max_withdraw(self: @TContractState, owner: ContractAddress) -> u256;
    fn preview_withdraw(self: @TContractState, assets: u256) -> u256;
    fn withdraw(
        ref self: TContractState, assets: u256, receiver: ContractAddress, owner: ContractAddress
    ) -> u256;
    fn max_redeem(self: @TContractState, owner: ContractAddress) -> u256;
    fn preview_redeem(self: @TContractState, shares: u256) -> u256;
    fn redeem(
        ref self: TContractState, shares: u256, receiver: ContractAddress, owner: ContractAddress
    ) -> u256;
}

#[derive(Drop, Copy, Serde)]
pub struct Claim {
    pub id: u64,
    pub claimee: ContractAddress,
    pub amount: u128,
}

#[starknet::interface]
pub trait IVault<TContractState> {
    fn set_manager(ref self: TContractState, manager: ContractAddress);
    // fn set_strategy(ref self: TContractState, strategy: ContractAddress);
    fn claim_strk_rewards(
        ref self: TContractState,
        rewardsContract: ContractAddress,
        claim: Claim,
        proof: Span<felt252>
    );
    fn swap(ref self: TContractState, swap: Array<Swap>, limit_amount: u128);
    fn modify_position(
        ref self: TContractState,
        pool_id: felt252,
        collateral_asset: ContractAddress,
        debt_asset: ContractAddress,
        collateral: Amount,
        debt: Amount
    ) -> UpdatePositionResponse;
    fn modify_lever(
        ref self: TContractState, modify_lever_params: ModifyLeverParams
    ) -> ModifyLeverResponse;
    fn nav(self: @TContractState) -> u256;

    fn deposit(ref self: TContractState, assets: u256, receiver: ContractAddress) -> u256;
    fn mint(ref self: TContractState, shares: u256, receiver: ContractAddress) -> u256;

    fn redeem(ref self: TContractState, receiver: ContractAddress, owner: ContractAddress) -> u256;
    fn request_redeem(ref self: TContractState, shares: u256);

    fn approve_singleton(ref self: TContractState);
}

#[starknet::interface]
pub trait IDefiSpringDistributor<TContractState> {
    fn claim(ref self: TContractState, amount: u128, proof: Span<felt252>);
}

#[derive(Serde, Drop, Clone)]
pub struct SwapParams {
    pub swap: Array<Swap>,
    pub limit_amount: u128
}

#[derive(Serde, Drop, Clone)]
pub enum VaultAction {
    Swap: SwapParams
}

#[derive(Serde, Drop, Clone)]
pub struct VaultParams {
    pub action: VaultAction
}

#[starknet::contract]
pub mod Vault {
    use core::integer::BoundedInt;
    use core::num::traits::{Zero};

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
        common::{i257, i257_new, calculate_collateral_and_debt_value}
    };
    use vesu_periphery::{
        swap::{swap, Swap},
        vault::{
            IVault, Claim, IDefiSpringDistributorDispatcher, IDefiSpringDistributorDispatcherTrait,
            VaultParams, VaultAction, SwapParams
        },
        // strategy::{IStrategyDispatcher, IStrategyDispatcherTrait},
        multiply::{
            IMultiplyDispatcher, IMultiplyDispatcherTrait, ModifyLeverParams, ModifyLeverResponse
        },
        position_list::{
            position_list_component, position_list_component::PositionListTrait, Position
        },
    };

    component!(path: position_list_component, storage: position_list, event: PositionListEvent);
    component!(path: ERC20Component, storage: erc20, event: ERC20Event);

    #[abi(embed_v0)]
    impl ERC20Impl = ERC20Component::ERC20Impl<ContractState>;
    #[abi(embed_v0)]
    impl ERC20MetadataImpl = ERC20Component::ERC20MetadataImpl<ContractState>;
    #[abi(embed_v0)]
    impl ERC20CamelOnlyImpl = ERC20Component::ERC20CamelOnlyImpl<ContractState>;
    impl ERC20InternalImpl = ERC20Component::InternalImpl<ContractState>;

    #[storage]
    struct Storage {
        manager: ContractAddress,
        // The Vesu singleton contract address
        singleton: ISingletonDispatcher,
        // The Ekubo core contract address
        ekubo_core: ICoreDispatcher,
        // The Multiply contract address
        multiply: IMultiplyDispatcher,
        // The underlying asset of the vToken
        asset: ContractAddress,
        // Flag indicating whether the asset is a legacy ERC20 token using camelCase or snake_case
        is_legacy: bool,
        // // The strategy contract address
        // strategy: IStrategyDispatcher,
        // // The settlement status of a user after triggering withdrawal or redemption
        // settlement_status: LegacyMap::<ContractAddress, (u256, u256, u64)>,

        redemption_requests: LegacyMap::<ContractAddress, (u64, u256, u256)>,
        // storage for the timestamp manager component
        #[substorage(v0)]
        position_list: position_list_component::Storage,
        // The ERC20 component
        #[substorage(v0)]
        erc20: ERC20Component::Storage,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        PositionListEvent: position_list_component::Event,
        #[flat]
        ERC20Event: ERC20Component::Event,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        name: felt252,
        symbol: felt252,
        decimals: u8,
        asset: ContractAddress,
        singleton: ContractAddress,
        ekubo_core: ContractAddress,
        multiply: ContractAddress
    ) {
        self.erc20.initializer(name, symbol, decimals);
        self.asset.write(asset);
        let singleton = ISingletonDispatcher { contract_address: singleton };
        IERC20Dispatcher { contract_address: asset }
            .approve(singleton.contract_address, BoundedInt::max());
        let (asset_config, _) = singleton.asset_config(0, asset);
        self.is_legacy.write(asset_config.is_legacy);
        self.singleton.write(singleton);
        self.ekubo_core.write(ICoreDispatcher { contract_address: ekubo_core });
        self.multiply.write(IMultiplyDispatcher { contract_address: multiply });
    }

    fn convert_to_assets(total_supply: u256, nav: u256, shares_delta: u256) -> u256 {
        let index = nav * SCALE / total_supply;
        shares_delta * index / SCALE
    }

    fn convert_to_shares(total_supply: u256, nav: u256, assets_delta: u256) -> u256 {
        let index = nav * SCALE / total_supply;
        assets_delta * SCALE / index
    }

    #[generate_trait]
    impl InternalFunctions of InternalFunctionsTrait {
        fn assert_manager_or_strategy(ref self: ContractState) {
            assert!(
                get_caller_address() == self
                    .manager
                    .read(), // || get_caller_address() == self.strategy.read().contract_address,
                "caller-not-manager-or-strategy"
            );
        }

        fn transfer_asset(
            self: @ContractState, sender: ContractAddress, to: ContractAddress, amount: u256
        ) {
            let asset = self.asset.read();
            let is_legacy = self.is_legacy.read();
            let erc20 = IERC20Dispatcher { contract_address: asset };
            if sender == get_contract_address() {
                assert!(erc20.transfer(to, amount), "transfer-failed");
            } else if is_legacy {
                assert!(erc20.transferFrom(sender, to, amount), "transferFrom-failed");
            } else {
                assert!(erc20.transfer_from(sender, to, amount), "transfer-from-failed");
            }
        }

        fn _swap(ref self: ContractState, params: SwapParams) {
            let SwapParams { swap, limit_amount } = params;
            let core = self.ekubo_core.read();
            let (input_amount, output_amount) = swap(core, swap, limit_amount);
            handle_delta(core, output_amount.token, output_amount.amount, get_contract_address());
            handle_delta(core, input_amount.token, input_amount.amount, get_contract_address());
        }
    }

    #[abi(embed_v0)]
    impl LockerImpl of ILocker<ContractState> {
        fn locked(ref self: ContractState, id: u32, mut data: Span<felt252>) -> Span<felt252> {
            let core = self.ekubo_core.read();

            // asserts that caller is core
            let vault_params: VaultParams = consume_callback_data(core, data);
            let vault_response = match vault_params.action {
                VaultAction::Swap(params) => self._swap(params)
            };

            let mut data: Array<felt252> = array![];
            Serde::serialize(@vault_response, ref data);
            data.span()
        }
    }

    #[abi(embed_v0)]
    impl VaultImpl of IVault<ContractState> {
        fn set_manager(ref self: ContractState, manager: ContractAddress) {
            self.assert_manager_or_strategy();
            self.manager.write(manager);
        }

        // fn set_strategy(ref self: ContractState, strategy: ContractAddress) {
        //     self.assert_manager_or_strategy();
        //     self.strategy.write(IStrategyDispatcher { contract_address: strategy });
        // }

        fn claim_strk_rewards(
            ref self: ContractState,
            rewardsContract: ContractAddress,
            claim: Claim,
            proof: Span<felt252>,
        ) {
            self.assert_manager_or_strategy();
            let defi_spring_distributor = IDefiSpringDistributorDispatcher {
                contract_address: rewardsContract
            };
            defi_spring_distributor.claim(claim.amount, proof);
        }

        fn swap(ref self: ContractState, swap: Array<Swap>, limit_amount: u128) {
            self.assert_manager_or_strategy();
            call_core_with_callback(self.ekubo_core.read(), @SwapParams { swap, limit_amount })
        }

        fn modify_position(
            ref self: ContractState,
            pool_id: felt252,
            collateral_asset: ContractAddress,
            debt_asset: ContractAddress,
            collateral: Amount,
            debt: Amount
        ) -> UpdatePositionResponse {
            self.assert_manager_or_strategy();
            let singleton = self.singleton.read();

            let (position_before, _, _) = singleton
                .position(pool_id, collateral_asset, debt_asset, get_contract_address());

            let response = singleton
                .modify_position(
                    ModifyPositionParams {
                        pool_id,
                        collateral_asset,
                        debt_asset,
                        user: get_contract_address(),
                        collateral: collateral,
                        debt: debt,
                        data: array![].span()
                    }
                );

            let (position_after, _, _) = singleton
                .position(pool_id, collateral_asset, debt_asset, get_contract_address());

            if position_before.collateral_shares == 0 && position_after.collateral_shares > 0 {
                self.position_list.push_front(Position { pool_id, collateral_asset, debt_asset });
            } else if position_before.collateral_shares > 0
                && position_after.collateral_shares == 0 {
                self.position_list.remove(Position { pool_id, collateral_asset, debt_asset });
            }

            response
        }

        fn modify_lever(
            ref self: ContractState, modify_lever_params: ModifyLeverParams
        ) -> ModifyLeverResponse {
            self.assert_manager_or_strategy();
            let multiply = self.multiply.read();
            multiply.modify_lever(modify_lever_params)
        }

        fn nav(self: @ContractState) -> u256 {
            let singleton = self.singleton.read();

            let mut assets = 0;
            let mut liabilities = 0;
            let mut position = self.position_list.first();

            while (position != Zero::zero()) {
                let Position { pool_id, collateral_asset, debt_asset } = position;
                let context = singleton
                    .context(pool_id, collateral_asset, debt_asset, get_contract_address());
                let (_, collateral_value, _, debt_value) = calculate_collateral_and_debt_value(
                    context, context.position
                );
                assets += collateral_value;
                liabilities += debt_value;
                position = self.position_list.next(position);
            };

            assets - liabilities
        }

        fn deposit(ref self: ContractState, assets: u256, receiver: ContractAddress) -> u256 {
            let asset = IERC20Dispatcher { contract_address: self.asset.read() };
            asset.transfer_from(get_caller_address(), get_contract_address(), assets);

            let vault_shares = convert_to_shares(self.erc20.total_supply(), self.nav(), assets);
            self.erc20._mint(receiver, vault_shares);

            vault_shares
        }

        fn mint(ref self: ContractState, shares: u256, receiver: ContractAddress) -> u256 {
            let assets = convert_to_assets(self.erc20.total_supply(), self.nav(), shares);

            let asset = IERC20Dispatcher { contract_address: self.asset.read() };
            asset.transfer_from(get_caller_address(), get_contract_address(), assets);

            self.erc20._mint(receiver, shares);

            assets
        }

        fn redeem(
            ref self: ContractState, receiver: ContractAddress, owner: ContractAddress
        ) -> u256 {
            let (timestamp, shares, nav_at_request) = self.redemption_requests.read(owner);

            assert!(timestamp + 86400 > get_block_timestamp(), "redeem-timeout");

            let mut nav = self.nav();
            if nav > nav_at_request {
                nav = nav_at_request
            }

            let assets = convert_to_assets(self.erc20.total_supply(), nav, shares);

            self.erc20._burn(owner, shares);

            IERC20Dispatcher { contract_address: self.asset.read() }.transfer(receiver, assets);

            assets
        }

        fn request_redeem(ref self: ContractState, shares: u256) {
            self
                .redemption_requests
                .write(get_caller_address(), (get_block_timestamp(), shares, self.nav()));
        }

        /// Re-approves the vToken to be spendable by the extension
        fn approve_singleton(ref self: ContractState) {
            IERC20Dispatcher { contract_address: self.asset.read() }
                .approve(self.singleton.read().contract_address, BoundedInt::max());
        }
    }
}
