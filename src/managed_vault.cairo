use starknet::ContractAddress;
use vesu::data_model::{Amount, AssetPrice, UpdatePositionResponse};
use vesu::vendor::pragma::AggregationMode;
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
    fn modify_asset_configuration(
        ref self: TContractState, asset: ContractAddress, asset_configuration: AssetConfig,
    );
    fn get_asset_configuration(
        self: @TContractState, asset: ContractAddress,
    ) -> Option<AssetConfig>;
    fn pragma_oracle(self: @TContractState) -> ContractAddress;
    fn set_oracle(ref self: TContractState, oracle_address: ContractAddress);
    fn price(self: @TContractState, asset: ContractAddress) -> AssetPrice;
    fn set_asset_configuration_parameter(
        ref self: TContractState, asset: ContractAddress, parameter: felt252, value: felt252,
    );

    fn set_deposit_fee(ref self: TContractState, fee: u16);
    fn get_deposit_fee(self: @TContractState) -> u16;
    fn set_withdrawal_fee(ref self: TContractState, fee: u16);
    fn get_withdrawal_fee(self: @TContractState) -> u16;
    fn set_performance_fee(ref self: TContractState, fee: u16);
    fn get_performance_fee(self: @TContractState) -> u16;
    fn set_fee_recipient(ref self: TContractState, recipient: ContractAddress);
    fn get_fee_recipient(self: @TContractState) -> ContractAddress;

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

    // Fee recipient functions
    fn pending_fees(self: @TContractState) -> u256;
    fn claim_fees(ref self: TContractState) -> u256;
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
#[derive(Serde, PartialEq, Drop, Clone, Default, Copy, starknet::Store)]
pub struct AssetConfig {
    pub is_legacy: bool,
    pub scale: u256,
    pub pragma_key: felt252,
    pub timeout: u64, // [seconds]
    pub number_of_sources: u32, // [0, 255]
    pub start_time_offset: u64, // [seconds]
    pub time_window: u64, // [seconds]
    pub aggregation_mode: AggregationMode,
}

#[starknet::contract]
pub mod ManagedVault {
    use core::num::traits::{Bounded, Zero};
    use ekubo::components::shared_locker::{
        call_core_with_callback, consume_callback_data, handle_delta,
    };
    use ekubo::interfaces::core::{ICoreDispatcher, ILocker};
    use starknet::storage::{
        Map, MutableVecTrait, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess, Vec, VecTrait,
    };
    use starknet::{ContractAddress, get_block_timestamp, get_caller_address, get_contract_address};
    use vesu::common::calculate_collateral_and_debt_value;
    use vesu::data_model::{Amount, AssetPrice, ModifyPositionParams, UpdatePositionResponse};
    use vesu::extension::interface::{IExtensionDispatcher, IExtensionDispatcherTrait};
    use vesu::math::pow_10;
    use vesu::singleton_v2::{ISingletonV2Dispatcher, ISingletonV2DispatcherTrait};
    use vesu::units::SCALE;
    use vesu::vendor::erc20::{ERC20ABIDispatcher as IERC20Dispatcher, ERC20ABIDispatcherTrait};
    use vesu::vendor::erc20_component::ERC20Component;
    use vesu::vendor::pragma::{DataType, IPragmaABIDispatcher, IPragmaABIDispatcherTrait};
    use vesu_periphery::managed_vault::{
        AssetConfig, Claim, IManagedVault, IMerkleDistributorDispatcher,
        IMerkleDistributorDispatcherTrait, SwapParams,
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

    // TODO Should it even be possible to allow 100% fees?
    const MAX_BPS: u16 = 100_00; // 100% in basis points

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
        // Oracle related storage
        pragma_oracle_address: ContractAddress,
        // List of all approved assets and their configuration
        // TODO This could be further improved by using a more efficient data structure
        asset_config: Vec<(ContractAddress, AssetConfig)>,
        // Fee configurations in basis points (bps)
        deposit_fee: u16,
        withdrawal_fee: u16,
        performance_fee: u16,
        fee_recipient: ContractAddress,
        last_index: u256,
        fee_shares: u256,
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
        oracle_address: ContractAddress,
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

        self.pragma_oracle_address.write(oracle_address);
    }

    #[generate_trait]
    impl InternalFunctions of InternalFunctionsTrait {
        fn assert_manager(ref self: ContractState) {
            assert!(get_caller_address() == self.manager.read(), "caller-not-manager");
        }

        fn assert_owner(ref self: ContractState) {
            assert!(get_caller_address() == self.owner.read(), "caller-not-owner");
        }

        fn assert_asset_approved(self: @ContractState, asset: ContractAddress) {
            assert!(self.get_asset_configuration(asset).is_some(), "asset-not-approved");
        }

        #[inline(always)]
        fn balance_of_self(self: @ContractState, asset: ContractAddress, is_legacy: bool) -> u256 {
            if is_legacy {
                IERC20Dispatcher { contract_address: asset }.balanceOf(get_contract_address())
            } else {
                IERC20Dispatcher { contract_address: asset }.balance_of(get_contract_address())
            }
        }

        fn assert_fair_rate(
            self: @ContractState,
            sell_token: ContractAddress,
            sell_amount: u256,
            buy_token: ContractAddress,
            buy_amount: u256,
        ) {
            let price_sell = self.price(sell_token);
            let price_buy = self.price(buy_token);
            assert_price(price_sell);
            assert_price(price_buy);
            // TODO Protect this with a read-only lock?
            // Since owner has to approve the asset, is it even useful?
            // TODO Configurable slippage
            let slippage_decimals = 4;
            let slippage_bps = 95_00; // 95% of the price
            // TODO Could use scale from the asset config instead of calling decimals
            let sell_token_decimals = IERC20Dispatcher { contract_address: sell_token }.decimals();
            let buy_token_decimals = IERC20Dispatcher { contract_address: buy_token }
                .decimals()
                .into();
            let decimals_total = sell_token_decimals.into() + slippage_decimals;
            // TODO handle rounding: has to be Ceil in this case
            let min_bought_amount = if decimals_total > buy_token_decimals {
                let scale_div = pow_10(decimals_total - buy_token_decimals);
                (sell_amount * price_sell.value * slippage_bps) / (price_buy.value * scale_div)
            } else {
                let scale_mul = pow_10(buy_token_decimals - decimals_total);
                (sell_amount * price_sell.value * scale_mul * slippage_bps) / (price_buy.value)
            };
            assert!(buy_amount >= min_bought_amount, "price-out-too-low");
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

        fn unsafe_compute_index(self: @ContractState, total_supply: u256, nav: u256) -> u256 {
            let last_index = if total_supply == 0 {
                SCALE
            } else {
                nav * SCALE / total_supply
            };
            last_index
        }

        fn compute_index(ref self: ContractState, total_supply: u256, nav: u256) -> u256 {
            let last_index = self.unsafe_compute_index(total_supply, nav);
            self.last_index.write(last_index);
            last_index
        }

        fn convert_to_assets(
            self: @ContractState, total_supply: u256, nav: u256, shares_delta: u256,
        ) -> u256 {
            let index = self.unsafe_compute_index(total_supply, nav);
            (shares_delta * index / SCALE) * self.scale.read() / SCALE
        }

        fn convert_to_shares(
            self: @ContractState, total_supply: u256, nav: u256, assets_delta: u256,
        ) -> u256 {
            let index = self.unsafe_compute_index(total_supply, nav);
            (assets_delta * SCALE / self.scale.read()) * SCALE / index
        }

        fn update_fee_shares(ref self: ContractState, shares: u256) {
            self.fee_shares.write(self.fee_shares.read() + shares);
            self.erc20.ERC20_total_supply.write(self.erc20.ERC20_total_supply.read() + shares);
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


        fn modify_asset_configuration(
            ref self: ContractState, asset: ContractAddress, asset_configuration: AssetConfig,
        ) {
            self.assert_owner();
            assert_asset_config(asset_configuration);

            for asset_index in 0..self.asset_config.len() {
                let (read_asset, _) = self.asset_config[asset_index].read();
                if asset == read_asset {
                    // TODO Should we allow to update an existing asset configuration?
                    self.asset_config[asset_index].write((read_asset, asset_configuration));
                    return;
                }
            }
            // If the asset configuration does not exist, add it
            self.asset_config.push((asset, asset_configuration));
        }

        fn get_asset_configuration(
            self: @ContractState, asset: ContractAddress,
        ) -> Option<AssetConfig> {
            for asset_index in 0..self.asset_config.len() {
                let (read_asset, config) = self.asset_config[asset_index].read();
                if read_asset == asset {
                    // Asset configuration was removed
                    if config == Default::default() {
                        return None;
                    }
                    return Some(config);
                }
            }
            None
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

        fn pragma_oracle(self: @ContractState) -> ContractAddress {
            self.pragma_oracle_address.read()
        }

        fn set_oracle(ref self: ContractState, oracle_address: ContractAddress) {
            self.assert_owner();
            assert!(self.pragma_oracle_address.read().is_zero(), "oracle-already-initialized");
            self.pragma_oracle_address.write(oracle_address);
        }

        fn price(self: @ContractState, asset: ContractAddress) -> AssetPrice {
            let AssetConfig {
                pragma_key,
                timeout,
                number_of_sources,
                start_time_offset,
                time_window,
                aggregation_mode,
                ..,
            } = self.get_asset_configuration(asset).expect('asset-not-approved');
            let dispatcher = IPragmaABIDispatcher {
                contract_address: self.pragma_oracle_address.read(),
            };
            let response = dispatcher.get_data(DataType::SpotEntry(pragma_key), aggregation_mode);

            // calculate the twap if start_time_offset and time_window are set
            assert!(start_time_offset != 0, "start-time-offset-must-be-set");
            assert!(time_window != 0, "time-window-must-be-set");
            let value = response.price.into() * SCALE / pow_10(response.decimals.into());

            // ensure that price is not stale and that the number of sources is sufficient
            let time_delta = if response.last_updated_timestamp >= get_block_timestamp() {
                0
            } else {
                get_block_timestamp() - response.last_updated_timestamp
            };
            let is_valid = (timeout == 0 || (timeout != 0 && time_delta <= timeout))
                && (number_of_sources == 0
                    || (number_of_sources != 0
                        && number_of_sources <= response.num_sources_aggregated));

            AssetPrice { value, is_valid }
        }

        fn set_asset_configuration_parameter(
            ref self: ContractState, asset: ContractAddress, parameter: felt252, value: felt252,
        ) {
            self.assert_owner();

            let mut oracle_config: AssetConfig = self
                .get_asset_configuration(asset)
                .expect('asset-not-approved');
            assert!(oracle_config.pragma_key != 0, "oracle-config-not-set");

            if parameter == 'is_legacy' {
                oracle_config.is_legacy = value == 0;
            } else if parameter == 'scale' {
                oracle_config.scale = value.try_into().unwrap();
            } else if parameter == 'pragma_key' {
                oracle_config.pragma_key = value;
            } else if parameter == 'timeout' {
                oracle_config.timeout = value.try_into().unwrap();
            } else if parameter == 'number_of_sources' {
                oracle_config.number_of_sources = value.try_into().unwrap();
            } else if parameter == 'start_time_offset' {
                oracle_config.start_time_offset = value.try_into().unwrap();
            } else if parameter == 'time_window' {
                oracle_config.time_window = value.try_into().unwrap();
            } else {
                assert!(false, "invalid-oracle-parameter");
            }

            assert_asset_config(oracle_config);
            self.modify_asset_configuration(asset, oracle_config);
            // self.emit(SetOracleParameter { asset, parameter, value });
        }

        // Fee management functions
        fn set_deposit_fee(ref self: ContractState, fee: u16) {
            self.assert_owner();
            assert!(fee <= MAX_BPS, "invalid-deposit-fee");
            self.deposit_fee.write(fee);
        }

        fn get_deposit_fee(self: @ContractState) -> u16 {
            self.deposit_fee.read()
        }

        fn set_withdrawal_fee(ref self: ContractState, fee: u16) {
            self.assert_owner();
            assert!(fee <= MAX_BPS, "invalid-withdrawal-fee");
            self.withdrawal_fee.write(fee);
        }

        fn get_withdrawal_fee(self: @ContractState) -> u16 {
            self.withdrawal_fee.read()
        }

        fn set_performance_fee(ref self: ContractState, fee: u16) {
            self.assert_owner();
            assert!(fee <= MAX_BPS, "invalid-performance-fee");
            self.performance_fee.write(fee);
        }

        fn get_performance_fee(self: @ContractState) -> u16 {
            self.performance_fee.read()
        }

        fn set_fee_recipient(ref self: ContractState, recipient: ContractAddress) {
            self.assert_owner();
            self.fee_recipient.write(recipient);
        }

        fn get_fee_recipient(self: @ContractState) -> ContractAddress {
            self.fee_recipient.read()
        }

        /////////////////////////
        // Manager functions
        /////////////////////////

        fn claim_rewards(
            ref self: ContractState,
            rewards_contract: ContractAddress,
            claim: Claim,
            proof: Span<felt252>,
        ) {
            self.assert_manager();
            // TODO What if the interface changes?
            // TODO Shouldn't this do more? Like swap + modify position?
            // TODO Check, should the reward contract be approved by the manager?
            IMerkleDistributorDispatcher { contract_address: rewards_contract }
                .claim(claim.amount, proof);
        }

        fn swap(ref self: ContractState, swap: Array<Swap>, limit_amount: u128) {
            self.assert_manager();

            assert!(limit_amount > 0, "invalid-limit-amount");
            let start_token = *swap[0].route[0].pool_key.token0;
            let last_swap = swap[swap.len() - 1];
            let end_token = *last_swap.route[last_swap.route.len() - 1].pool_key.token1;
            self.assert_asset_approved(start_token);
            self.assert_asset_approved(end_token);

            let AssetConfig {
                is_legacy: is_legacy_start_token, ..,
            } = self.get_asset_configuration(start_token).unwrap();
            let balance_start_before = self.balance_of_self(start_token, is_legacy_start_token);
            let AssetConfig {
                is_legacy: is_legacy_end_token, ..,
            } = self.get_asset_configuration(end_token).unwrap();
            let balance_end_before = self.balance_of_self(end_token, is_legacy_end_token);
            // Do the swap
            let _: () = call_core_with_callback(
                self.ekubo_core.read(), @SwapParams { swap, limit_amount },
            );

            let balance_start_after = self.balance_of_self(start_token, is_legacy_start_token);
            let balance_end_after = self.balance_of_self(end_token, is_legacy_end_token);
            // Decide which token is in/out based on the balance change
            let is_selling_start_token = balance_start_after < balance_start_before;
            let (sell_token, sell_amount, buy_token, buy_amount) = if is_selling_start_token {
                assert!(balance_end_after > balance_end_before, "swap-balance-mismatch");
                (
                    start_token,
                    balance_start_before - balance_start_after,
                    end_token,
                    balance_end_after - balance_end_before,
                )
            } else {
                assert!(balance_end_before > balance_end_after, "swap-balance-mismatch");
                (
                    end_token,
                    balance_end_before - balance_end_after,
                    start_token,
                    balance_start_after - balance_start_before,
                )
            };

            self.assert_fair_rate(sell_token, sell_amount, buy_token, buy_amount);
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
            self.assert_asset_approved(collateral_asset);
            self.assert_asset_approved(debt_asset);

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
                        collateral,
                        debt,
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

            self.assert_asset_approved(collateral_asset);
            self.assert_asset_approved(debt_asset);

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
            let this = get_contract_address();

            let mut assets = 0;
            let mut liabilities = 0;
            let mut position = self.position_list.first();

            while (position != Zero::zero()) {
                let Position { pool_id, collateral_asset, debt_asset } = position;
                let context = singleton.context(pool_id, collateral_asset, debt_asset, this);
                let (_, collateral_value, _, debt_value) = calculate_collateral_and_debt_value(
                    context, context.position,
                );
                assets += collateral_value;
                liabilities += debt_value;
                position = self.position_list.next(position);
            }

            let asset = self.asset.read();
            let balance = self.balance_of_self(asset.contract_address, self.is_legacy.read());

            let (extension, pool_id) = self.price_source();
            let extension = IExtensionDispatcher { contract_address: extension };
            let price = extension.price(pool_id, asset.contract_address);
            assets += balance * price.value / self.scale.read();

            // Loop through all approved assets and add their value
            for asset_index in 0..self.asset_config.len() {
                let (read_asset, config) = self.asset_config[asset_index].read();
                // Skip if the asset configuration was removed
                if config == Default::default() {
                    continue;
                }

                // Skip if the asset is the vault's underlying asset
                // This is important to avoid double counting the asset
                if read_asset == asset.contract_address {
                    continue;
                }
                let AssetConfig { is_legacy, scale, .. } = config;
                let balance = self.balance_of_self(read_asset, is_legacy);
                let asset_price = self.price(read_asset);
                assert_price(asset_price);
                assets += balance * asset_price.value / scale;
            }

            assets - liabilities
        }

        // Returns the amount of shares that the receiver will receive
        fn deposit(ref self: ContractState, assets: u256, receiver: ContractAddress) -> u256 {
            self.transfer_asset(get_caller_address(), get_contract_address(), assets);

            let mut vault_shares = self
                .convert_to_shares(self.erc20.total_supply(), self.nav(), assets);

            let deposit_fee = self.deposit_fee.read();
            if deposit_fee > 0 {
                // TODO Rounding
                let fee_amount = (vault_shares * deposit_fee.into()) / MAX_BPS.into();
                vault_shares -= fee_amount;
                self.update_fee_shares(fee_amount);
            }

            self.erc20._mint(receiver, vault_shares);

            vault_shares
        }

        fn mint(ref self: ContractState, mut shares: u256, receiver: ContractAddress) -> u256 {
            let assets = self.convert_to_assets(self.erc20.total_supply(), self.nav(), shares);

            self.transfer_asset(get_caller_address(), get_contract_address(), assets);

            let deposit_fee = self.deposit_fee.read();
            if deposit_fee > 0 {
                // TODO Rounding
                let fee_amount = (shares * deposit_fee.into()) / MAX_BPS.into();
                shares -= fee_amount;
                self.update_fee_shares(fee_amount);
            }

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

            let mut user_shares = shares;
            let withdraw_fee = self.withdrawal_fee.read();
            if withdraw_fee > 0 {
                // TODO Rounding
                let fee_amount = (user_shares * withdraw_fee.into()) / MAX_BPS.into();
                user_shares -= fee_amount;
                self.update_fee_shares(fee_amount);
            }

            println!("per_share_nav: {}", per_share_nav);
            let assets = (user_shares * per_share_nav / SCALE) * self.scale.read() / SCALE;

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

        // Fee recipient functions
        fn pending_fees(self: @ContractState) -> u256 {
            self.fee_shares.read()
        }

        fn claim_fees(ref self: ContractState) -> u256 {
            let fee_recipient = self.get_fee_recipient();
            assert!(fee_recipient.is_non_zero(), "fee-recipient-not-set");
            assert!(get_caller_address() == fee_recipient, "caller-not-fee-recipient");
            let fee_shares = self.fee_shares.read();
            // Remove the fees from total supply
            self.erc20.ERC20_total_supply.write(self.erc20.ERC20_total_supply.read() - fee_shares);
            // Mint them to the fee recipient
            self.erc20._mint(fee_recipient, fee_shares);

            fee_shares
        }
    }

    pub fn assert_asset_config(asset_config: AssetConfig) {
        assert!(asset_config.pragma_key != 0, "pragma-key-must-be-set");
        assert!(
            asset_config.time_window <= asset_config.start_time_offset,
            "time-window-must-be-less-than-start-time-offset",
        );
    }

    fn assert_price(price: AssetPrice) {
        assert!(price.is_valid, "price-invalid");
        assert!(price.value != 0, "price-zero");
    }
}
