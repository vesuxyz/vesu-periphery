use starknet::ContractAddress;

#[cfg(test)]
mod Test_Proxy {
    use snforge_std::{start_prank, stop_prank, start_warp, stop_warp, CheatTarget, load};
    use starknet::{
        ContractAddress, contract_address_const, get_block_timestamp, get_caller_address,
        get_contract_address, account::Call
    };
    use core::num::traits::{Zero};
    use ekubo::{
        interfaces::{
            core::{ICoreDispatcher, ICoreDispatcherTrait, ILocker, SwapParameters},
            erc20::{IERC20Dispatcher, IERC20DispatcherTrait}
        },
        types::{i129::{i129_new, i129Trait}, keys::{PoolKey},}
    };
    use vesu::{
        units::{SCALE, SCALE_128},
        data_model::{Amount, AmountType, AmountDenomination, ModifyPositionParams, LTVConfig},
        singleton::{ISingletonDispatcher, ISingletonDispatcherTrait}, test::setup::deploy_with_args,
        common::{i257, i257_new},
        extension::default_extension_po::{
            IDefaultExtensionDispatcher, IDefaultExtensionDispatcherTrait, ShutdownMode
        }
    };
    use vesu_periphery::multiply4626::{
        IMultiply4626Dispatcher, IMultiply4626DispatcherTrait, ModifyLeverParams,
        IncreaseLeverParams, ModifyLeverAction, I4626Dispatcher, I4626DispatcherTrait
    };
    use vesu_periphery::swap::{RouteNode, TokenAmount, Swap};
    use vesu_periphery::proxy::{IProxyDispatcher, IProxyDispatcherTrait};

    struct TestConfig {
        eth: IERC20Dispatcher,
        usdc: IERC20Dispatcher,
        singleton: ISingletonDispatcher,
        extension: IDefaultExtensionDispatcher,
        pool_id: felt252,
        manager: ContractAddress,
        pauser: ContractAddress,
        proxy: IProxyDispatcher,
    }

    fn setup() -> TestConfig {
        let eth = IERC20Dispatcher {
            contract_address: contract_address_const::<
                0x049d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7
            >()
        };
        let usdc = IERC20Dispatcher {
            contract_address: contract_address_const::<
                0x053c91253bc9682c04929ca02ed00b3e423f6710d2ee7e0d5ebb06f3ecf368a8
            >()
        };

        let singleton = ISingletonDispatcher {
            contract_address: contract_address_const::<
                0x2545b2e5d519fc230e9cd781046d3a64e092114f07e44771e0d719d148725ef
            >()
        };

        let pool_id = 2198503327643286920898110335698706244522220458610657370981979460625005526824;

        let extension = IDefaultExtensionDispatcher {
            contract_address: singleton.extension(pool_id)
        };

        let manager = extension.pool_owner(pool_id);
        let pauser = contract_address_const::<'0x1'>();

        let proxy = IProxyDispatcher {
            contract_address: deploy_with_args("Proxy", array![manager.into()])
        };

        start_prank(CheatTarget::One(extension.contract_address), manager);
        extension.set_pool_owner(pool_id, proxy.contract_address);
        stop_prank(CheatTarget::One(extension.contract_address));

        TestConfig { eth, usdc, singleton, extension, pool_id, manager, pauser, proxy, }
    }

    #[test]
    #[available_gas(20000000)]
    #[should_panic(expected: "caller-not-manager")]
    #[fork("Mainnet")]
    fn test_proxy_set_manager_caller_not_manager() {
        let config = setup();
        let TestConfig { proxy, .. } = config;

        proxy.set_manager(get_caller_address());
    }

    #[test]
    #[available_gas(20000000)]
    #[fork("Mainnet")]
    fn test_proxy_set_manager() {
        let config = setup();
        let TestConfig { manager, proxy, .. } = config;

        assert!(proxy.manager() != get_caller_address());

        start_prank(CheatTarget::One(proxy.contract_address), manager);
        proxy.set_manager(get_caller_address());
        stop_prank(CheatTarget::One(proxy.contract_address));

        assert!(proxy.manager() == get_caller_address());
    }

    #[test]
    #[available_gas(20000000)]
    #[should_panic(expected: "caller-not-manager")]
    #[fork("Mainnet")]
    fn test_proxy_set_caller_for_method_caller_not_manager() {
        let config = setup();
        let TestConfig { extension, proxy, pauser, .. } = config;

        proxy
            .set_caller_for_method(
                pauser, extension.contract_address, selector!("singleton"), true
            );
    }

    #[test]
    #[available_gas(20000000)]
    #[fork("Mainnet")]
    fn test_proxy_set_caller_for_method() {
        let config = setup();
        let TestConfig { extension, manager, proxy, pauser, .. } = config;

        assert!(!proxy.access_control(pauser, extension.contract_address, selector!("singleton")));

        start_prank(CheatTarget::One(proxy.contract_address), manager);
        proxy
            .set_caller_for_method(
                pauser, extension.contract_address, selector!("singleton"), true
            );
        stop_prank(CheatTarget::One(proxy.contract_address));

        assert!(proxy.access_control(pauser, extension.contract_address, selector!("singleton")));

        start_prank(CheatTarget::One(proxy.contract_address), pauser);
        proxy
            .proxy_call(
                array![
                    Call {
                        to: extension.contract_address,
                        selector: selector!("singleton"),
                        calldata: array![].span()
                    }
                ]
                    .span()
            );
        stop_prank(CheatTarget::One(proxy.contract_address));

        start_prank(CheatTarget::One(proxy.contract_address), manager);
        proxy
            .set_caller_for_method(
                pauser, extension.contract_address, selector!("singleton"), false
            );
        stop_prank(CheatTarget::One(proxy.contract_address));
    }

    #[test]
    #[available_gas(20000000)]
    #[should_panic(expected: "caller-not-authorized")]
    #[fork("Mainnet")]
    fn test_proxy_set_caller_for_method_caller_not_authorized() {
        let config = setup();
        let TestConfig { extension, manager, proxy, pauser, .. } = config;

        assert!(!proxy.access_control(pauser, extension.contract_address, selector!("singleton")));

        start_prank(CheatTarget::One(proxy.contract_address), manager);
        proxy
            .set_caller_for_method(
                pauser, extension.contract_address, selector!("singleton"), true
            );
        stop_prank(CheatTarget::One(proxy.contract_address));

        assert!(proxy.access_control(pauser, extension.contract_address, selector!("singleton")));

        start_prank(CheatTarget::One(proxy.contract_address), pauser);
        proxy
            .proxy_call(
                array![
                    Call {
                        to: extension.contract_address,
                        selector: selector!("singleton"),
                        calldata: array![].span()
                    }
                ]
                    .span()
            );
        stop_prank(CheatTarget::One(proxy.contract_address));

        start_prank(CheatTarget::One(proxy.contract_address), manager);
        proxy
            .set_caller_for_method(
                pauser, extension.contract_address, selector!("singleton"), false
            );
        stop_prank(CheatTarget::One(proxy.contract_address));

        assert!(!proxy.access_control(pauser, extension.contract_address, selector!("singleton")));

        start_prank(CheatTarget::One(proxy.contract_address), pauser);

        proxy
            .proxy_call(
                array![
                    Call {
                        to: extension.contract_address,
                        selector: selector!("singleton"),
                        calldata: array![].span()
                    }
                ]
                    .span()
            );
    }

    #[test]
    #[available_gas(20000000)]
    #[fork("Mainnet")]
    fn test_proxy_proxy_call() {
        let config = setup();
        let TestConfig { eth, usdc, extension, pool_id, manager, proxy, .. } = config;

        start_prank(CheatTarget::One(proxy.contract_address), manager);

        let mut ltv_config_serialized = array![];
        LTVConfig { max_ltv: 0 }.serialize(ref ltv_config_serialized);

        let mut calldata = array![
            pool_id, usdc.contract_address.into(), eth.contract_address.into(),
        ];

        while !ltv_config_serialized
            .is_empty() {
                let item = ltv_config_serialized.pop_front().unwrap();
                calldata.append(item);
            };

        proxy
            .proxy_call(
                array![
                    Call {
                        to: extension.contract_address,
                        selector: selector!("set_shutdown_ltv_config"),
                        calldata: calldata.span()
                    }
                ]
                    .span()
            );

        stop_prank(CheatTarget::One(proxy.contract_address));

        let shutdown_mode = extension
            .update_shutdown_status(pool_id, usdc.contract_address, eth.contract_address);
        assert!(shutdown_mode == ShutdownMode::Recovery);

        start_prank(CheatTarget::One(proxy.contract_address), manager);

        let mut ltv_config_serialized = array![];
        LTVConfig { max_ltv: SCALE.try_into().unwrap() }.serialize(ref ltv_config_serialized);

        let mut calldata = array![
            pool_id, usdc.contract_address.into(), eth.contract_address.into(),
        ];

        while !ltv_config_serialized
            .is_empty() {
                let item = ltv_config_serialized.pop_front().unwrap();
                calldata.append(item);
            };

        proxy
            .proxy_call(
                array![
                    Call {
                        to: extension.contract_address,
                        selector: selector!("set_shutdown_ltv_config"),
                        calldata: calldata.span()
                    }
                ]
                    .span()
            );

        stop_prank(CheatTarget::One(proxy.contract_address));

        let shutdown_mode = extension
            .update_shutdown_status(pool_id, usdc.contract_address, eth.contract_address);
        assert!(shutdown_mode == ShutdownMode::None);
    }

    #[test]
    #[available_gas(20000000)]
    #[should_panic(expected: "caller-not-authorized")]
    #[fork("Mainnet")]
    fn test_proxy_proxy_call_pauser_caller_not_authorized() {
        let config = setup();
        let TestConfig { eth, usdc, extension, pool_id, pauser, proxy, .. } = config;

        start_prank(CheatTarget::One(proxy.contract_address), pauser);

        let mut ltv_config_serialized = array![];
        LTVConfig { max_ltv: 0 }.serialize(ref ltv_config_serialized);

        let mut calldata = array![
            pool_id, usdc.contract_address.into(), eth.contract_address.into(),
        ];

        while !ltv_config_serialized
            .is_empty() {
                let item = ltv_config_serialized.pop_front().unwrap();
                calldata.append(item);
            };

        proxy
            .proxy_call(
                array![
                    Call {
                        to: extension.contract_address,
                        selector: selector!("set_shutdown_ltv_config"),
                        calldata: calldata.span()
                    }
                ]
                    .span()
            );

        stop_prank(CheatTarget::One(proxy.contract_address));
    }

    #[test]
    #[available_gas(20000000)]
    #[fork("Mainnet")]
    fn test_proxy_proxy_call_pauser() {
        let config = setup();
        let TestConfig { eth, usdc, extension, pool_id, manager, pauser, proxy, .. } = config;

        start_prank(CheatTarget::One(proxy.contract_address), manager);
        proxy
            .set_caller_for_method(
                pauser, extension.contract_address, selector!("set_shutdown_ltv_config"), true
            );
        stop_prank(CheatTarget::One(proxy.contract_address));

        start_prank(CheatTarget::One(proxy.contract_address), pauser);

        let mut ltv_config_serialized = array![];
        LTVConfig { max_ltv: 0 }.serialize(ref ltv_config_serialized);

        let mut calldata = array![
            pool_id, usdc.contract_address.into(), eth.contract_address.into(),
        ];

        while !ltv_config_serialized
            .is_empty() {
                let item = ltv_config_serialized.pop_front().unwrap();
                calldata.append(item);
            };

        proxy
            .proxy_call(
                array![
                    Call {
                        to: extension.contract_address,
                        selector: selector!("set_shutdown_ltv_config"),
                        calldata: calldata.span()
                    }
                ]
                    .span()
            );

        stop_prank(CheatTarget::One(proxy.contract_address));

        let shutdown_mode = extension
            .update_shutdown_status(pool_id, usdc.contract_address, eth.contract_address);
        assert!(shutdown_mode == ShutdownMode::Recovery);
    }
}
