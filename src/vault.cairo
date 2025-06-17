use starknet::{account::Call, ContractAddress};
use vesu_periphery::swap::Swap;
use vesu::{common::{i257, i257_new}, data_model::{Amount}};

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
    fn claim_strk_rewards(
        ref self: TContractState,
        rewardsContract: ContractAddress,
        claim: Claim,
        proof: Span<felt252>
    );
    fn swap(ref self: TContractState, swap: Array<Swap>, limit_amount: u128);
    fn compound(ref self: TContractState, compound_asset: ContractAddress) -> u256;
    fn deposit(ref self: TContractState, assets: u256, receiver: ContractAddress) -> u256;
    fn mint(ref self: TContractState, shares: u256, receiver: ContractAddress) -> u256;
    fn withdraw(
        ref self: TContractState, assets: u256, receiver: ContractAddress, owner: ContractAddress
    ) -> u256;
    fn redeem(
        ref self: TContractState, shares: u256, receiver: ContractAddress, owner: ContractAddress
    ) -> u256;
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

#[derive(Serde, Drop, Clone)]
pub struct StrategyResponse {
    pub pool_id: felt252,
    pub collateral_asset: ContractAddress,
    pub debt_asset: ContractAddress,
}

#[starknet::interface]
pub trait IStrategy<TContractState> {
    fn on_compound(
        ref self: TContractState, compound_asset: ContractAddress
    ) -> (StrategyResponse, u256);
    fn on_deposit(ref self: TContractState) -> StrategyResponse;
    fn on_withdraw(ref self: TContractState) -> StrategyResponse;
}

#[starknet::contract]
pub mod Vault {
    use core::integer::BoundedInt;

    use starknet::{
        account::Call, syscalls::call_contract_syscall, ContractAddress, get_caller_address,
        get_contract_address
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
        swap::{swap, Swap},
        vault::{
            IVault, Claim, IDefiSpringDistributorDispatcher, IDefiSpringDistributorDispatcherTrait,
            VaultParams, VaultAction, SwapParams, IStrategyDispatcher, IStrategyDispatcherTrait,
            StrategyResponse
        }
    };

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
        // The singleton contract address
        singleton: ISingletonDispatcher,
        // The core contract address
        core: ICoreDispatcher,
        // The underlying asset of the vToken
        asset: ContractAddress,
        // Flag indicating whether the asset is a legacy ERC20 token using camelCase or snake_case
        is_legacy: bool,
        // The strategy contract address
        strategy: IStrategyDispatcher,
        // The ERC20 component
        #[substorage(v0)]
        erc20: ERC20Component::Storage,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
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
        core: ContractAddress
    ) {
        self.erc20.initializer(name, symbol, decimals);
        self.asset.write(asset);
        let singleton = ISingletonDispatcher { contract_address: singleton };
        IERC20Dispatcher { contract_address: asset }
            .approve(singleton.contract_address, BoundedInt::max());
        let (asset_config, _) = singleton.asset_config(0, asset);
        self.is_legacy.write(asset_config.is_legacy);
        self.singleton.write(singleton);
        self.core.write(ICoreDispatcher { contract_address: core });
    }

    fn convert_to_collateral_shares(
        total_supply: u256, total_collateral_shares: u256, vault_shares_delta: u256
    ) -> u256 {
        let index = total_collateral_shares * SCALE / total_supply;
        vault_shares_delta * index / SCALE
    }

    fn convert_to_vault_shares(
        total_supply: u256, total_collateral_shares: u256, collateral_shares_delta: u256
    ) -> u256 {
        let index = total_collateral_shares * SCALE / total_supply;
        collateral_shares_delta * SCALE / index
    }

    #[generate_trait]
    impl InternalFunctions of InternalFunctionsTrait {
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
            let core = self.core.read();
            let (input_amount, output_amount) = swap(core, swap, limit_amount);
            handle_delta(core, output_amount.token, output_amount.amount, get_contract_address());
            handle_delta(core, input_amount.token, input_amount.amount, get_contract_address());
        }
    }

    #[abi(embed_v0)]
    impl LockerImpl of ILocker<ContractState> {
        fn locked(ref self: ContractState, id: u32, mut data: Span<felt252>) -> Span<felt252> {
            let core = self.core.read();

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
        fn claim_strk_rewards(
            ref self: ContractState,
            rewardsContract: ContractAddress,
            claim: Claim,
            proof: Span<felt252>,
        ) {
            assert!(get_caller_address() == self.manager.read(), "caller-not-manager");
            let defi_spring_distributor = IDefiSpringDistributorDispatcher {
                contract_address: rewardsContract
            };
            defi_spring_distributor.claim(claim.amount, proof);
        }

        fn swap(ref self: ContractState, swap: Array<Swap>, limit_amount: u128) {
            assert!(get_caller_address() == self.manager.read(), "caller-not-manager");
            call_core_with_callback(self.core.read(), @SwapParams { swap, limit_amount })
        }

        fn compound(ref self: ContractState, compound_asset: ContractAddress) -> u256 {
            assert!(get_caller_address() == self.manager.read(), "caller-not-manager");

            let singleton = self.singleton.read();
            let strategy = self.strategy.read();

            // call the strategy's on_compound hook
            let (StrategyResponse { pool_id, collateral_asset, debt_asset }, amount) = strategy
                .on_compound(compound_asset);

            // deposit the assets into singleton
            singleton
                .modify_position(
                    ModifyPositionParams {
                        pool_id,
                        collateral_asset,
                        debt_asset,
                        user: get_contract_address(),
                        collateral: Amount {
                            amount_type: AmountType::Delta,
                            denomination: AmountDenomination::Assets,
                            value: i257_new(amount, false)
                        },
                        debt: Default::default(),
                        data: array![].span()
                    }
                );

            amount
        }

        // deposit (underlier)
        // (underlier -> collateral_shares) -> vault_shares
        fn deposit(ref self: ContractState, assets: u256, receiver: ContractAddress) -> u256 {
            let singleton = self.singleton.read();
            let strategy = self.strategy.read();

            // transfer assets from sender to vault
            let asset = IERC20Dispatcher { contract_address: self.asset.read() };
            asset.transfer_from(get_caller_address(), get_contract_address(), assets);
            asset.approve(strategy.contract_address, assets);

            // call the strategy's on_deposit hook
            let StrategyResponse { pool_id, collateral_asset, debt_asset } = strategy.on_deposit();

            // deposit assets into singleton
            let UpdatePositionResponse { collateral_shares_delta, .. } = singleton
                .modify_position(
                    ModifyPositionParams {
                        pool_id,
                        collateral_asset,
                        debt_asset,
                        user: get_contract_address(),
                        collateral: Amount {
                            amount_type: AmountType::Delta,
                            denomination: AmountDenomination::Assets,
                            value: i257_new(assets, false)
                        },
                        debt: Default::default(),
                        data: array![].span()
                    }
                );

            // mint vault shares to receiver
            let (asset_config, _) = singleton.asset_config(pool_id, collateral_asset);
            let vault_shares = convert_to_vault_shares(
                self.erc20.total_supply(),
                asset_config.total_collateral_shares,
                collateral_shares_delta.abs
            );
            self.erc20._mint(receiver, vault_shares);

            vault_shares
        }

        // mint (vault_shares)
        // vault_shares -> (collateral_shares -> underlier)
        fn mint(ref self: ContractState, shares: u256, receiver: ContractAddress) -> u256 {
            let singleton = self.singleton.read();
            let strategy = self.strategy.read();

            let StrategyResponse { pool_id, collateral_asset, debt_asset } = strategy.on_deposit();

            let (asset_config, _) = singleton.asset_config(pool_id, collateral_asset);
            let collateral_shares = convert_to_collateral_shares(
                self.erc20.total_supply(), asset_config.total_collateral_shares, shares
            );

            let UpdatePositionResponse { collateral_delta, .. } = singleton
                .modify_position(
                    ModifyPositionParams {
                        pool_id,
                        collateral_asset,
                        debt_asset,
                        user: get_contract_address(),
                        collateral: Amount {
                            amount_type: AmountType::Delta,
                            denomination: AmountDenomination::Native,
                            value: i257_new(collateral_shares, false)
                        },
                        debt: Default::default(),
                        data: array![].span()
                    }
                );

            // mint vault shares to receiver
            self.erc20._mint(receiver, shares);

            collateral_delta.abs
        }

        // withdraw( underlier)
        // (underlier -> collateral_shares) -> vault_shares
        fn withdraw(
            ref self: ContractState, assets: u256, receiver: ContractAddress, owner: ContractAddress
        ) -> u256 {
            let singleton = self.singleton.read();
            let strategy = self.strategy.read();

            // call the strategy's on_before_withdraw hook
            let StrategyResponse { pool_id, collateral_asset, debt_asset } = strategy.on_withdraw();

            // withdraw assets from singleton
            let UpdatePositionResponse { collateral_shares_delta, .. } = singleton
                .modify_position(
                    ModifyPositionParams {
                        pool_id,
                        collateral_asset,
                        debt_asset,
                        user: owner,
                        collateral: Amount {
                            amount_type: AmountType::Delta,
                            denomination: AmountDenomination::Assets,
                            value: i257_new(assets, true)
                        },
                        debt: Default::default(),
                        data: array![].span()
                    }
                );

            // burn vault shares from owner
            let (asset_config, _) = singleton.asset_config(pool_id, collateral_asset);
            let vault_shares = convert_to_vault_shares(
                self.erc20.total_supply(),
                asset_config.total_collateral_shares,
                collateral_shares_delta.abs
            );
            self.erc20._burn(owner, vault_shares);

            // transfer assets from vault to receiver
            IERC20Dispatcher { contract_address: self.asset.read() }.transfer(receiver, assets);

            vault_shares
        }

        // redeem(vault_shares)
        // vault_shares -> (collateral_shares -> underlier)
        fn redeem(
            ref self: ContractState, shares: u256, receiver: ContractAddress, owner: ContractAddress
        ) -> u256 {
            let singleton = self.singleton.read();
            let strategy = self.strategy.read();

            // call the strategy's on_before_withdraw hook
            let StrategyResponse { pool_id, collateral_asset, debt_asset } = strategy.on_withdraw();

            let (asset_config, _) = singleton.asset_config(pool_id, collateral_asset);
            let collateral_shares = convert_to_collateral_shares(
                self.erc20.total_supply(), asset_config.total_collateral_shares, shares
            );

            // withdraw assets from singleton
            let UpdatePositionResponse { collateral_delta, .. } = singleton
                .modify_position(
                    ModifyPositionParams {
                        pool_id,
                        collateral_asset,
                        debt_asset,
                        user: owner,
                        collateral: Amount {
                            amount_type: AmountType::Delta,
                            denomination: AmountDenomination::Native,
                            value: i257_new(collateral_shares, true)
                        },
                        debt: Default::default(),
                        data: array![].span()
                    }
                );

            // burn vault shares from owner
            self.erc20._burn(owner, shares);

            // transfer assets from vault to receiver
            IERC20Dispatcher { contract_address: self.asset.read() }
                .transfer(receiver, collateral_delta.abs);

            collateral_delta.abs
        }

        /// Re-approves the vToken to be spendable by the extension
        fn approve_singleton(ref self: ContractState) {
            IERC20Dispatcher { contract_address: self.asset.read() }
                .approve(self.singleton.read().contract_address, BoundedInt::max());
        }
    }
}
