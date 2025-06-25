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
    fn set_strategy(ref self: TContractState, strategy: ContractAddress);
    fn claim_rewards(
        ref self: TContractState,
        rewards_contract: ContractAddress,
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

    fn set_redemption_timeout(ref self: TContractState, timeout: u64);

    fn approve_singleton(ref self: TContractState);
}

#[starknet::interface]
pub trait IMerkleDistributor<TContractState> {
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
            IVault, Claim, IMerkleDistributorDispatcher, IMerkleDistributorDispatcherTrait,
            VaultParams, VaultAction, SwapParams
        },
        strategy::{IStrategyDispatcher, IStrategyDispatcherTrait},
        multiply::{
            IMultiplyDispatcher, IMultiplyDispatcherTrait, ModifyLeverParams, ModifyLeverResponse,
            ModifyLeverAction
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
        // The underlying asset of the vToken
        asset: IERC20Dispatcher,
        // Flag indicating whether the asset is a legacy ERC20 token using camelCase or snake_case
        is_legacy: bool,
        // The vault manager address
        manager: ContractAddress,
        // The strategy contract address
        strategy: IStrategyDispatcher,
        // The Vesu singleton contract address
        singleton: ISingletonDispatcher,
        // The Ekubo core contract address
        ekubo_core: ICoreDispatcher,
        // The Multiply contract address
        multiply: IMultiplyDispatcher,
        // The redemption timeout in seconds
        redemption_timeout: u64,
        // Map of redemption requests
        // (user, (timestamp, shares, nav_per_share_at_request))
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
        manager: ContractAddress,
        singleton: ContractAddress,
        ekubo_core: ContractAddress,
        multiply: ContractAddress,
        redemption_timeout: u64
    ) {
        self.erc20.initializer(name, symbol, decimals);

        self.asset.write(IERC20Dispatcher { contract_address: asset });
        let singleton = ISingletonDispatcher { contract_address: singleton };
        IERC20Dispatcher { contract_address: asset }
            .approve(singleton.contract_address, BoundedInt::max());
        let (asset_config, _) = singleton.asset_config(0, asset);
        self.is_legacy.write(asset_config.is_legacy);

        self.manager.write(manager);

        self.singleton.write(singleton);
        self.ekubo_core.write(ICoreDispatcher { contract_address: ekubo_core });
        self.multiply.write(IMultiplyDispatcher { contract_address: multiply });

        self.redemption_timeout.write(redemption_timeout);
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
        fn assert_manager(ref self: ContractState) {
            assert!(get_caller_address() == self.manager.read(), "caller-not-manager");
        }

        fn assert_manager_or_strategy(ref self: ContractState) {
            assert!(
                get_caller_address() == self.manager.read()
                    || get_caller_address() == self.strategy.read().contract_address,
                "caller-not-manager-or-strategy"
            );
        }

        fn transfer_asset(
            self: @ContractState, sender: ContractAddress, to: ContractAddress, amount: u256
        ) {
            let asset = self.asset.read();
            let is_legacy = self.is_legacy.read();
            if sender == get_contract_address() {
                assert!(asset.transfer(to, amount), "transfer-failed");
            } else if is_legacy {
                assert!(asset.transferFrom(sender, to, amount), "transferFrom-failed");
            } else {
                assert!(asset.transfer_from(sender, to, amount), "transfer-from-failed");
            }
        }

        fn _swap(ref self: ContractState, params: SwapParams) {
            let SwapParams { swap, limit_amount } = params;
            let core = self.ekubo_core.read();
            let (input_amount, output_amount) = swap(core, swap, limit_amount);
            handle_delta(core, output_amount.token, output_amount.amount, get_contract_address());
            handle_delta(core, input_amount.token, input_amount.amount, get_contract_address());
        }

        fn update_position_list(
            ref self: ContractState,
            pool_id: felt252,
            collateral_asset: ContractAddress,
            debt_asset: ContractAddress,
            collateral_shares_before: u256,
            collateral_shares_after: u256
        ) {
            if collateral_shares_before == 0 && collateral_shares_after > 0 {
                self.position_list.push_front(Position { pool_id, collateral_asset, debt_asset });
            } else if collateral_shares_before > 0 && collateral_shares_after == 0 {
                self.position_list.remove(Position { pool_id, collateral_asset, debt_asset });
            }
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
            self.assert_manager();
            self.manager.write(manager);
        }

        fn set_strategy(ref self: ContractState, strategy: ContractAddress) {
            self.assert_manager();
            self.strategy.write(IStrategyDispatcher { contract_address: strategy });
        }

        fn claim_rewards(
            ref self: ContractState,
            rewards_contract: ContractAddress,
            claim: Claim,
            proof: Span<felt252>,
        ) {
            self.assert_manager_or_strategy();
            let merkle_distributor = IMerkleDistributorDispatcher {
                contract_address: rewards_contract
            };
            merkle_distributor.claim(claim.amount, proof);
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

            self
                .update_position_list(
                    pool_id,
                    collateral_asset,
                    debt_asset,
                    position_before.collateral_shares,
                    position_after.collateral_shares
                );

            response
        }

        fn modify_lever(
            ref self: ContractState, modify_lever_params: ModifyLeverParams
        ) -> ModifyLeverResponse {
            self.assert_manager_or_strategy();
            let singleton = self.singleton.read();

            let (pool_id, collateral_asset, debt_asset) = match modify_lever_params.clone().action {
                ModifyLeverAction::IncreaseLever(params) => (
                    params.pool_id, params.collateral_asset, params.debt_asset
                ),
                ModifyLeverAction::DecreaseLever(params) => (
                    params.pool_id, params.collateral_asset, params.debt_asset
                )
            };

            let (position_before, _, _) = singleton
                .position(pool_id, collateral_asset, debt_asset, get_contract_address());

            let multiply = self.multiply.read();
            let response = multiply.modify_lever(modify_lever_params);

            let (position_after, _, _) = singleton
                .position(pool_id, collateral_asset, debt_asset, get_contract_address());

            self
                .update_position_list(
                    pool_id,
                    collateral_asset,
                    debt_asset,
                    position_before.collateral_shares,
                    position_after.collateral_shares
                );

            response
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

            if self.is_legacy.read() {
                assets += self.asset.read().balanceOf(get_contract_address());
            } else {
                assets += self.asset.read().balance_of(get_contract_address());
            }

            assets - liabilities
        }

        fn deposit(ref self: ContractState, assets: u256, receiver: ContractAddress) -> u256 {
            self.asset.read().transfer_from(get_caller_address(), get_contract_address(), assets);

            let vault_shares = convert_to_shares(self.erc20.total_supply(), self.nav(), assets);
            self.erc20._mint(receiver, vault_shares);

            vault_shares
        }

        fn mint(ref self: ContractState, shares: u256, receiver: ContractAddress) -> u256 {
            let assets = convert_to_assets(self.erc20.total_supply(), self.nav(), shares);

            self.asset.read().transfer_from(get_caller_address(), get_contract_address(), assets);

            self.erc20._mint(receiver, shares);

            assets
        }

        fn redeem(
            ref self: ContractState, receiver: ContractAddress, owner: ContractAddress
        ) -> u256 {
            let (timestamp, shares, nav_per_share_at_request) = self
                .redemption_requests
                .read(owner);

            assert!(
                timestamp + self.redemption_timeout.read() > get_block_timestamp(), "redeem-timeout"
            );

            let mut per_share_nav = convert_to_assets(self.erc20.total_supply(), self.nav(), SCALE);
            if per_share_nav > nav_per_share_at_request {
                per_share_nav = nav_per_share_at_request
            }

            let assets = shares * per_share_nav / SCALE;

            self.erc20._burn(owner, shares);

            self.asset.read().transfer(receiver, assets);

            assets
        }

        fn request_redeem(ref self: ContractState, shares: u256) {
            let per_share_nav = convert_to_assets(self.erc20.total_supply(), self.nav(), SCALE);

            self
                .redemption_requests
                .write(get_caller_address(), (get_block_timestamp(), shares, per_share_nav));
        }

        /// Re-approves the vToken to be spendable by the extension
        fn approve_singleton(ref self: ContractState) {
            self.asset.read().approve(self.singleton.read().contract_address, BoundedInt::max());
        }

        fn set_redemption_timeout(ref self: ContractState, timeout: u64) {
            self.assert_manager_or_strategy();
            self.redemption_timeout.write(timeout);
        }
    }
}
