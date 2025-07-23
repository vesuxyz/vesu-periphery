use starknet::ContractAddress;
use vesu::data_model::{Amount, UpdatePositionResponse};
use vesu_periphery::multiply::{ModifyLeverParams, ModifyLeverResponse};
use vesu_periphery::swap::Swap;

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
        ref self: TContractState, assets: u256, receiver: ContractAddress, owner: ContractAddress,
    ) -> u256;
    fn max_redeem(self: @TContractState, owner: ContractAddress) -> u256;
    fn preview_redeem(self: @TContractState, shares: u256) -> u256;
    fn redeem(
        ref self: TContractState, shares: u256, receiver: ContractAddress, owner: ContractAddress,
    ) -> u256;
}

#[derive(Drop, Copy, Serde)]
pub struct Claim {
    pub id: u64,
    pub claimee: ContractAddress,
    pub amount: u128,
}

#[starknet::interface]
pub trait IManagedVault<TContractState> {
    // Owner functions
    fn set_manager(ref self: TContractState, manager: ContractAddress);
    fn set_price_source(ref self: TContractState, extension: ContractAddress, pool_id: felt252);
    fn price_source(self: @TContractState) -> (ContractAddress, felt252);
    fn set_redemption_timeout(ref self: TContractState, timeout: u64);
    fn modify_delegation(
        ref self: TContractState, pool_id: felt252, delegatee: ContractAddress, delegation: bool,
    );
    fn modify_pool_id_status(ref self: TContractState, pool_id: felt252, is_approved: bool);
    fn is_pool_id_approved(self: @TContractState, pool_id: felt252) -> bool;

    // Management functions
    fn claim_rewards(
        ref self: TContractState,
        rewards_contract: ContractAddress,
        claim: Claim,
        proof: Span<felt252>,
    );
    fn swap(ref self: TContractState, swap: Array<Swap>, limit_amount: u128);
    fn modify_position(
        ref self: TContractState,
        pool_id: felt252,
        collateral_asset: ContractAddress,
        debt_asset: ContractAddress,
        collateral: Amount,
        debt: Amount,
    ) -> UpdatePositionResponse;
    fn modify_lever(
        ref self: TContractState, modify_lever_params: ModifyLeverParams,
    ) -> ModifyLeverResponse;
    fn nav(self: @TContractState) -> u256;

    // User related functions
    fn deposit(ref self: TContractState, assets: u256, receiver: ContractAddress) -> u256;
    fn mint(ref self: TContractState, shares: u256, receiver: ContractAddress) -> u256;

    fn redeem(ref self: TContractState, receiver: ContractAddress, owner: ContractAddress) -> u256;
    fn request_redeem(ref self: TContractState, shares: u256);
}

#[starknet::interface]
pub trait IMerkleDistributor<TContractState> {
    fn claim(ref self: TContractState, amount: u128, proof: Span<felt252>);
}

#[derive(Serde, Drop, Clone)]
pub struct SwapParams {
    pub swap: Array<Swap>,
    pub limit_amount: u128,
}

#[starknet::contract]
pub mod ManagedVault {
    use core::num::traits::{Bounded, Zero};
    use ekubo::components::shared_locker::{
        call_core_with_callback, consume_callback_data, handle_delta,
    };
    use ekubo::interfaces::core::{ICoreDispatcher, ILocker};
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
    use starknet::{ContractAddress, get_block_timestamp, get_caller_address, get_contract_address};
    use vesu::common::calculate_collateral_and_debt_value;
    use vesu::data_model::{Amount, ModifyPositionParams, UpdatePositionResponse};
    use vesu::extension::interface::{IExtensionDispatcher, IExtensionDispatcherTrait};
    use vesu::math::pow_10;
    use vesu::singleton_v2::{ISingletonV2Dispatcher, ISingletonV2DispatcherTrait};
    use vesu::units::SCALE;
    use vesu::vendor::erc20::{ERC20ABIDispatcher as IERC20Dispatcher, ERC20ABIDispatcherTrait};
    use vesu::vendor::erc20_component::ERC20Component;
    use vesu_periphery::managed_vault::{
        Claim, IManagedVault, IMerkleDistributorDispatcher, IMerkleDistributorDispatcherTrait,
        SwapParams,
    };
    use vesu_periphery::multiply::{
        IMultiplyDispatcher, IMultiplyDispatcherTrait, ModifyLeverAction, ModifyLeverParams,
        ModifyLeverResponse,
    };
    use vesu_periphery::swap::{Swap, swap};
    use vesu_periphery::utils::position_list::position_list_component::PositionListTrait;
    use vesu_periphery::utils::position_list::{Position, position_list_component};

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
        // The vault's underlying asset
        asset: IERC20Dispatcher,
        // Scale of the vault's underlying asset
        scale: u256,
        // Flag indicating whether the asset is a legacy ERC20 token using camelCase or snake_case
        is_legacy: bool,
        // The price source extension address
        // (extension, pool_id)
        price_source: (ContractAddress, felt252),
        // The vault owner address
        owner: ContractAddress,
        // The vault manager address
        manager: ContractAddress,
        // The Vesu singleton contract address
        singleton: ISingletonV2Dispatcher,
        // The Ekubo core contract address
        ekubo_core: ICoreDispatcher,
        // The Multiply contract address
        multiply: IMultiplyDispatcher,
        // The redemption timeout in seconds
        redemption_timeout: u64,
        // Map of redemption requests
        // (user, (timestamp, shares, nav_per_share_at_request))
        redemption_requests: Map<ContractAddress, (u64, u256, u256)>,
        // Map pools accepted by the owner
        // (pool_id, is_approved)
        approved_pool_ids: Map<felt252, bool>,
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
        is_legacy: bool,
        owner: ContractAddress,
        manager: ContractAddress,
        singleton: ContractAddress,
        ekubo_core: ContractAddress,
        multiply: ContractAddress,
        redemption_timeout: u64,
    ) {
        self.erc20.initializer(name, symbol, decimals);

        self.asset.write(IERC20Dispatcher { contract_address: asset });
        self.scale.write(pow_10(IERC20Dispatcher { contract_address: asset }.decimals().into()));
        IERC20Dispatcher { contract_address: asset }.approve(singleton, Bounded::MAX);
        self.is_legacy.write(is_legacy);

        self.owner.write(owner);
        self.manager.write(manager);

        self.singleton.write(ISingletonV2Dispatcher { contract_address: singleton });
        self.ekubo_core.write(ICoreDispatcher { contract_address: ekubo_core });
        self.multiply.write(IMultiplyDispatcher { contract_address: multiply });

        self.redemption_timeout.write(redemption_timeout);
    }

    #[generate_trait]
    impl InternalFunctions of InternalFunctionsTrait {
        fn assert_manager(ref self: ContractState) {
            assert!(get_caller_address() == self.manager.read(), "caller-not-manager");
        }

        fn assert_owner(ref self: ContractState) {
            assert!(get_caller_address() == self.owner.read(), "caller-not-owner");
        }

        fn assert_pool_id_approved(ref self: ContractState, pool_id: felt252) {
            assert!(self.is_pool_id_approved(pool_id), "pool-not-accepted");
        }

        fn transfer_asset(
            self: @ContractState, sender: ContractAddress, to: ContractAddress, amount: u256,
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
            let core = self.ekubo_core.read();
            let (input_amount, output_amount) = swap(core, params.swap, params.limit_amount);
            handle_delta(core, output_amount.token, output_amount.amount, get_contract_address());
            handle_delta(core, input_amount.token, input_amount.amount, get_contract_address());
        }

        fn update_position_list(
            ref self: ContractState,
            pool_id: felt252,
            collateral_asset: ContractAddress,
            debt_asset: ContractAddress,
            collateral_shares_before: u256,
            collateral_shares_after: u256,
        ) {
            if collateral_shares_before == 0 && collateral_shares_after > 0 {
                self.position_list.push_front(Position { pool_id, collateral_asset, debt_asset });
            } else if collateral_shares_before > 0 && collateral_shares_after == 0 {
                self.position_list.remove(Position { pool_id, collateral_asset, debt_asset });
            }
        }

        fn compute_index(self: @ContractState, total_supply: u256, nav: u256) -> u256 {
            if total_supply == 0 {
                SCALE
            } else {
                nav * SCALE / total_supply
            }
        }

        fn convert_to_assets(
            self: @ContractState, total_supply: u256, nav: u256, shares_delta: u256,
        ) -> u256 {
            let index = self.compute_index(total_supply, nav);
            (shares_delta * index / SCALE) * self.scale.read() / SCALE
        }

        fn convert_to_shares(
            self: @ContractState, total_supply: u256, nav: u256, assets_delta: u256,
        ) -> u256 {
            let index = self.compute_index(total_supply, nav);
            (assets_delta * SCALE / self.scale.read()) * SCALE / index
        }
    }

    #[abi(embed_v0)]
    impl LockerImpl of ILocker<ContractState> {
        fn locked(ref self: ContractState, id: u32, mut data: Span<felt252>) -> Span<felt252> {
            let core = self.ekubo_core.read();

            // asserts that caller is core
            let swap_params: SwapParams = consume_callback_data(core, data);
            let swap_response = self._swap(swap_params);

            let mut data: Array<felt252> = array![];
            Serde::serialize(@swap_response, ref data);
            data.span()
        }
    }

    #[abi(embed_v0)]
    impl ManagedVaultImpl of IManagedVault<ContractState> {
        fn set_manager(ref self: ContractState, manager: ContractAddress) {
            self.assert_owner();
            self.manager.write(manager);
        }

        fn set_price_source(ref self: ContractState, extension: ContractAddress, pool_id: felt252) {
            self.assert_owner();
            self.price_source.write((extension, pool_id));
        }

        fn price_source(self: @ContractState) -> (ContractAddress, felt252) {
            self.price_source.read()
        }

        fn set_redemption_timeout(ref self: ContractState, timeout: u64) {
            self.assert_owner();
            self.redemption_timeout.write(timeout);
        }

        fn modify_delegation(
            ref self: ContractState, pool_id: felt252, delegatee: ContractAddress, delegation: bool,
        ) {
            self.assert_owner();
            self.singleton.read().modify_delegation(pool_id, delegatee, delegation);
        }

        fn modify_pool_id_status(ref self: ContractState, pool_id: felt252, is_approved: bool) {
            self.assert_owner();
            self.approved_pool_ids.write(pool_id, is_approved);
        }

        fn is_pool_id_approved(self: @ContractState, pool_id: felt252) -> bool {
            self.approved_pool_ids.read(pool_id)
        }

        fn claim_rewards(
            ref self: ContractState,
            rewards_contract: ContractAddress,
            claim: Claim,
            proof: Span<felt252>,
        ) {
            self.assert_manager();
            // TODO What if the interface changes?
            IMerkleDistributorDispatcher { contract_address: rewards_contract }
                .claim(claim.amount, proof);
        }

        fn swap(ref self: ContractState, swap: Array<Swap>, limit_amount: u128) {
            self.assert_manager();
            assert!(limit_amount > 0, "invalid-limit-amount");
            // TODO Protect with an oracle enforced min slippage
            call_core_with_callback(self.ekubo_core.read(), @SwapParams { swap, limit_amount })
        }

        fn modify_position(
            ref self: ContractState,
            pool_id: felt252,
            collateral_asset: ContractAddress,
            debt_asset: ContractAddress,
            collateral: Amount,
            debt: Amount,
        ) -> UpdatePositionResponse {
            self.assert_manager();
            self.assert_pool_id_approved(pool_id);

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
                        data: array![].span(),
                    },
                );

            let (position_after, _, _) = singleton
                .position(pool_id, collateral_asset, debt_asset, get_contract_address());

            self
                .update_position_list(
                    pool_id,
                    collateral_asset,
                    debt_asset,
                    position_before.collateral_shares,
                    position_after.collateral_shares,
                );

            response
        }

        fn modify_lever(
            ref self: ContractState, modify_lever_params: ModifyLeverParams,
        ) -> ModifyLeverResponse {
            self.assert_manager();

            let singleton = self.singleton.read();

            let (pool_id, collateral_asset, debt_asset, lever_swap_limit_amount) =
                match modify_lever_params.clone().action {
                ModifyLeverAction::IncreaseLever(params) => (
                    params.pool_id,
                    params.collateral_asset,
                    params.debt_asset,
                    params.lever_swap_limit_amount,
                ),
                ModifyLeverAction::DecreaseLever(params) => (
                    params.pool_id,
                    params.collateral_asset,
                    params.debt_asset,
                    params.lever_swap_limit_amount,
                ),
            };

            self.assert_pool_id_approved(pool_id);
            assert!(lever_swap_limit_amount > 0, "invalid-lever-swap-limit-amount");

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
                    position_after.collateral_shares,
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
                    context, context.position,
                );
                assets += collateral_value;
                liabilities += debt_value;
                position = self.position_list.next(position);
            }

            let balance = if self.is_legacy.read() {
                self.asset.read().balanceOf(get_contract_address())
            } else {
                self.asset.read().balance_of(get_contract_address())
            };

            let (extension, pool_id) = self.price_source.read();
            let price = IExtensionDispatcher { contract_address: extension }
                .price(pool_id, self.asset.read().contract_address);
            assets += balance * price.value / self.scale.read();

            assets - liabilities
        }

        fn deposit(ref self: ContractState, assets: u256, receiver: ContractAddress) -> u256 {
            self.transfer_asset(get_caller_address(), get_contract_address(), assets);

            let vault_shares = self
                .convert_to_shares(self.erc20.total_supply(), self.nav(), assets);
            self.erc20._mint(receiver, vault_shares);

            vault_shares
        }

        fn mint(ref self: ContractState, shares: u256, receiver: ContractAddress) -> u256 {
            let assets = self.convert_to_assets(self.erc20.total_supply(), self.nav(), shares);

            self.transfer_asset(get_caller_address(), get_contract_address(), assets);

            self.erc20._mint(receiver, shares);

            assets
        }

        fn redeem(
            ref self: ContractState, receiver: ContractAddress, owner: ContractAddress,
        ) -> u256 {
            let (timestamp, shares, nav_per_share_at_request) = self
                .redemption_requests
                .read(owner);

            assert!(
                timestamp + self.redemption_timeout.read() >= get_block_timestamp(),
                "redeem-timeout",
            );

            let mut per_share_nav = self.compute_index(self.erc20.total_supply(), self.nav());
            if per_share_nav > nav_per_share_at_request {
                per_share_nav = nav_per_share_at_request
            }

            println!("per_share_nav: {}", per_share_nav);
            let assets = (shares * per_share_nav / SCALE) * self.scale.read() / SCALE;

            println!("assets: {}", assets);

            self.erc20._burn(owner, shares);

            println!("balance: {}", self.asset.read().balanceOf(get_contract_address()));

            self.transfer_asset(get_contract_address(), receiver, assets);

            assets
        }

        fn request_redeem(ref self: ContractState, shares: u256) {
            assert!(self.erc20.balance_of(get_caller_address()) >= shares, "insufficient-shares");

            let per_share_nav = self.compute_index(self.erc20.total_supply(), self.nav());

            self
                .redemption_requests
                .write(get_caller_address(), (get_block_timestamp(), shares, per_share_nav));
        }
    }
}
