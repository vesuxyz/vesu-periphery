#[cfg(test)]
mod Test_Proxy {
    use ekubo::interfaces::erc20::IERC20Dispatcher;
    use snforge_std::{CheatSpan, cheat_caller_address};
    use starknet::account::Call;
    use starknet::{ContractAddress, get_caller_address};
    use vesu::data_model::LTVConfig;
    use vesu::extension::components::position_hooks::ShutdownMode;
    use vesu::extension::default_extension_po_v2::{
        IDefaultExtensionPOV2Dispatcher, IDefaultExtensionPOV2DispatcherTrait,
    };
    use vesu::singleton_v2::{ISingletonV2Dispatcher, ISingletonV2DispatcherTrait};
    use vesu::test::setup_v2::deploy_with_args;
    use vesu::units::SCALE;
    use vesu_periphery::proxy::{IProxyDispatcher, IProxyDispatcherTrait};

    struct TestConfig {
        eth: IERC20Dispatcher,
        usdc: IERC20Dispatcher,
        singleton: ISingletonV2Dispatcher,
        extension: IDefaultExtensionPOV2Dispatcher,
        pool_id: felt252,
        manager: ContractAddress,
        pauser: ContractAddress,
        proxy: IProxyDispatcher,
    }

    fn setup() -> TestConfig {
        let eth = IERC20Dispatcher {
            contract_address: 0x049d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7
                .try_into()
                .unwrap(),
        };
        let usdc = IERC20Dispatcher {
            contract_address: 0x053c91253bc9682c04929ca02ed00b3e423f6710d2ee7e0d5ebb06f3ecf368a8
                .try_into()
                .unwrap(),
        };

        let singleton = ISingletonV2Dispatcher {
            contract_address: 0x2545b2e5d519fc230e9cd781046d3a64e092114f07e44771e0d719d148725ef
                .try_into()
                .unwrap(),
        };

        let pool_id = 2198503327643286920898110335698706244522220458610657370981979460625005526824;

        let extension = IDefaultExtensionPOV2Dispatcher {
            contract_address: singleton.extension(pool_id),
        };

        let manager = extension.pool_owner(pool_id);
        let pauser = '0x1'.try_into().unwrap();

        let proxy = IProxyDispatcher {
            contract_address: deploy_with_args("Proxy", array![manager.into()]),
        };

        cheat_caller_address(extension.contract_address, manager, CheatSpan::TargetCalls(1));
        extension.set_pool_owner(pool_id, proxy.contract_address);

        TestConfig { eth, usdc, singleton, extension, pool_id, manager, pauser, proxy }
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

        cheat_caller_address(proxy.contract_address, manager, CheatSpan::TargetCalls(1));
        proxy.set_manager(get_caller_address());

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
                pauser, extension.contract_address, selector!("singleton"), true,
            );
    }

    #[test]
    #[available_gas(20000000)]
    #[fork("Mainnet")]
    fn test_proxy_set_caller_for_method() {
        let config = setup();
        let TestConfig { extension, manager, proxy, pauser, .. } = config;

        assert!(!proxy.access_control(pauser, extension.contract_address, selector!("singleton")));

        cheat_caller_address(proxy.contract_address, manager, CheatSpan::TargetCalls(1));
        proxy
            .set_caller_for_method(
                pauser, extension.contract_address, selector!("singleton"), true,
            );

        assert!(proxy.access_control(pauser, extension.contract_address, selector!("singleton")));

        cheat_caller_address(proxy.contract_address, pauser, CheatSpan::TargetCalls(1));
        proxy
            .proxy_call(
                array![
                    Call {
                        to: extension.contract_address,
                        selector: selector!("singleton"),
                        calldata: array![].span(),
                    },
                ]
                    .span(),
            );

        cheat_caller_address(proxy.contract_address, manager, CheatSpan::TargetCalls(1));
        proxy
            .set_caller_for_method(
                pauser, extension.contract_address, selector!("singleton"), false,
            );
    }

    #[test]
    #[available_gas(20000000)]
    #[should_panic(expected: "caller-not-authorized")]
    #[fork("Mainnet")]
    fn test_proxy_set_caller_for_method_caller_not_authorized() {
        let config = setup();
        let TestConfig { extension, manager, proxy, pauser, .. } = config;

        assert!(!proxy.access_control(pauser, extension.contract_address, selector!("singleton")));

        cheat_caller_address(proxy.contract_address, manager, CheatSpan::TargetCalls(1));
        proxy
            .set_caller_for_method(
                pauser, extension.contract_address, selector!("singleton"), true,
            );

        assert!(proxy.access_control(pauser, extension.contract_address, selector!("singleton")));

        cheat_caller_address(proxy.contract_address, pauser, CheatSpan::TargetCalls(1));
        proxy
            .proxy_call(
                array![
                    Call {
                        to: extension.contract_address,
                        selector: selector!("singleton"),
                        calldata: array![].span(),
                    },
                ]
                    .span(),
            );

        cheat_caller_address(proxy.contract_address, manager, CheatSpan::TargetCalls(1));
        proxy
            .set_caller_for_method(
                pauser, extension.contract_address, selector!("singleton"), false,
            );

        assert!(!proxy.access_control(pauser, extension.contract_address, selector!("singleton")));

        cheat_caller_address(proxy.contract_address, pauser, CheatSpan::TargetCalls(1));

        proxy
            .proxy_call(
                array![
                    Call {
                        to: extension.contract_address,
                        selector: selector!("singleton"),
                        calldata: array![].span(),
                    },
                ]
                    .span(),
            );
    }

    #[test]
    #[available_gas(20000000)]
    #[fork("Mainnet")]
    fn test_proxy_proxy_call() {
        let config = setup();
        let TestConfig { eth, usdc, extension, pool_id, manager, proxy, .. } = config;

        cheat_caller_address(proxy.contract_address, manager, CheatSpan::TargetCalls(1));

        let mut ltv_config_serialized = array![];
        LTVConfig { max_ltv: 0 }.serialize(ref ltv_config_serialized);

        let mut calldata = array![
            pool_id, usdc.contract_address.into(), eth.contract_address.into(),
        ];

        while !ltv_config_serialized.is_empty() {
            let item = ltv_config_serialized.pop_front().unwrap();
            calldata.append(item);
        }

        proxy
            .proxy_call(
                array![
                    Call {
                        to: extension.contract_address,
                        selector: selector!("set_shutdown_ltv_config"),
                        calldata: calldata.span(),
                    },
                ]
                    .span(),
            );

        let shutdown_mode = extension
            .update_shutdown_status(pool_id, usdc.contract_address, eth.contract_address);
        assert!(shutdown_mode == ShutdownMode::Recovery);

        cheat_caller_address(proxy.contract_address, manager, CheatSpan::TargetCalls(1));

        let mut ltv_config_serialized = array![];
        LTVConfig { max_ltv: SCALE.try_into().unwrap() }.serialize(ref ltv_config_serialized);

        let mut calldata = array![
            pool_id, usdc.contract_address.into(), eth.contract_address.into(),
        ];

        while !ltv_config_serialized.is_empty() {
            let item = ltv_config_serialized.pop_front().unwrap();
            calldata.append(item);
        }

        proxy
            .proxy_call(
                array![
                    Call {
                        to: extension.contract_address,
                        selector: selector!("set_shutdown_ltv_config"),
                        calldata: calldata.span(),
                    },
                ]
                    .span(),
            );

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

        cheat_caller_address(proxy.contract_address, pauser, CheatSpan::TargetCalls(1));

        let mut ltv_config_serialized = array![];
        LTVConfig { max_ltv: 0 }.serialize(ref ltv_config_serialized);

        let mut calldata = array![
            pool_id, usdc.contract_address.into(), eth.contract_address.into(),
        ];

        while !ltv_config_serialized.is_empty() {
            let item = ltv_config_serialized.pop_front().unwrap();
            calldata.append(item);
        }

        proxy
            .proxy_call(
                array![
                    Call {
                        to: extension.contract_address,
                        selector: selector!("set_shutdown_ltv_config"),
                        calldata: calldata.span(),
                    },
                ]
                    .span(),
            );
    }

    #[test]
    #[available_gas(20000000)]
    #[fork("Mainnet")]
    fn test_proxy_proxy_call_pauser() {
        let config = setup();
        let TestConfig { eth, usdc, extension, pool_id, manager, pauser, proxy, .. } = config;

        cheat_caller_address(proxy.contract_address, manager, CheatSpan::TargetCalls(1));
        proxy
            .set_caller_for_method(
                pauser, extension.contract_address, selector!("set_shutdown_ltv_config"), true,
            );

        cheat_caller_address((proxy.contract_address), pauser, CheatSpan::TargetCalls(1));

        let mut ltv_config_serialized = array![];
        LTVConfig { max_ltv: 0 }.serialize(ref ltv_config_serialized);

        let mut calldata = array![
            pool_id, usdc.contract_address.into(), eth.contract_address.into(),
        ];

        while !ltv_config_serialized.is_empty() {
            let item = ltv_config_serialized.pop_front().unwrap();
            calldata.append(item);
        }

        proxy
            .proxy_call(
                array![
                    Call {
                        to: extension.contract_address,
                        selector: selector!("set_shutdown_ltv_config"),
                        calldata: calldata.span(),
                    },
                ]
                    .span(),
            );

        let shutdown_mode = extension
            .update_shutdown_status(pool_id, usdc.contract_address, eth.contract_address);
        assert!(shutdown_mode == ShutdownMode::Recovery);
    }
}
