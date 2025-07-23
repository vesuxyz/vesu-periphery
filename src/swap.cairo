use ekubo::interfaces::core::{ICoreDispatcher, ICoreDispatcherTrait, SwapParameters};
use ekubo::types::i129::{i129, i129Trait};
use ekubo::types::keys::PoolKey;
use starknet::ContractAddress;
use vesu::units::{SCALE, SCALE_128};
use crate::i129_new;

#[derive(Serde, Copy, Drop)]
pub struct RouteNode {
    pub pool_key: PoolKey,
    pub sqrt_ratio_limit: u256,
    pub skip_ahead: u128,
}

#[derive(Serde, Copy, Drop)]
pub struct TokenAmount {
    pub token: ContractAddress,
    pub amount: i129,
}

#[derive(Serde, Drop, Clone)]
pub struct Swap {
    pub route: Array<RouteNode>,
    pub token_amount: TokenAmount,
}

pub fn assert_empty_token_amounts(mut swaps: Array<Swap>) {
    while let Option::Some(swap) = swaps.pop_front() {
        assert!(swap.token_amount.amount.mag == 0, "invalid-swap-token-amount");
    };
}

pub fn assert_matching_token_amounts(mut swaps: Array<Swap>) -> bool {
    let mut token: Option<ContractAddress> = Option::None;
    let mut is_negative: Option<bool> = Option::None;
    while let Option::Some(swap) = swaps.pop_front() {
        if let Option::Some(token) = token {
            assert!(
                token == swap.token_amount.token
                    && is_negative.unwrap() == swap.token_amount.amount.is_negative(),
                "swap-token-amount-mismatch",
            );
        } else {
            token = Option::Some(swap.token_amount.token);
            is_negative = Option::Some(swap.token_amount.amount.is_negative());
        }
    }

    is_negative.unwrap()
}

pub fn apply_weights(
    mut swaps: Array<Swap>, mut relative_weights: Array<u128>, total_amount: i129,
) -> Array<Swap> {
    assert!(swaps.len() == relative_weights.len(), "swaps-relative-weights-length-mismatch");

    let mut weight_sum = 0_u128;
    let mut allocated_amount = 0_u128;
    let mut adjusted_swaps = ArrayTrait::new();

    while let Option::Some(swap) = swaps.pop_front() {
        let percentage = relative_weights.pop_front().unwrap();
        let mut amount_scaled: u256 = total_amount.mag.into() * percentage.into() / SCALE;
        let mut amount = i129_new(amount_scaled.try_into().unwrap(), total_amount.is_negative());

        allocated_amount += amount.mag;
        weight_sum += percentage;

        // allocate residual amount to the last swap due to rounding errors
        if swaps.len() == 0 && total_amount.mag > allocated_amount.into() {
            let rest = total_amount.mag - allocated_amount;
            allocated_amount += rest;
            amount = i129_new(amount.mag + rest.into(), amount.is_negative());
        }
        adjusted_swaps
            .append(
                Swap {
                    route: swap.route,
                    token_amount: TokenAmount { token: swap.token_amount.token, amount: amount },
                },
            );
    }

    assert!(weight_sum == SCALE_128, "weight-sum-not-1");

    adjusted_swaps
}

pub fn swap(
    core: ICoreDispatcher, mut swaps: Array<Swap>, limit_amount: u128,
) -> (TokenAmount, TokenAmount) {
    let is_negative = assert_matching_token_amounts(swaps.clone());

    let mut input_amount: Option<TokenAmount> = Option::None;
    let mut output_amount: Option<TokenAmount> = Option::None;

    while let Option::Some(swap) = swaps.pop_front() {
        let mut route = swap.route;
        let mut token_amount = swap.token_amount;

        // we track this to know how much to pay in the case of exact input and how much to pull in
        // the case of exact output
        let mut first_swap_amount: Option<TokenAmount> = Option::None;

        while let Option::Some(node) = route.pop_front() {
            let is_token1 = token_amount.token == node.pool_key.token1;

            let delta = core
                .swap(
                    node.pool_key,
                    SwapParameters {
                        amount: token_amount.amount,
                        is_token1: is_token1,
                        sqrt_ratio_limit: node.sqrt_ratio_limit,
                        skip_ahead: node.skip_ahead,
                    },
                );

            if is_token1 {
                assert!(delta.amount1.mag == token_amount.amount.mag, "partial-swap");
            } else {
                assert!(delta.amount0.mag == token_amount.amount.mag, "partial-swap");
            }

            if first_swap_amount.is_none() {
                first_swap_amount =
                    if is_token1 {
                        Option::Some(
                            TokenAmount { token: node.pool_key.token1, amount: delta.amount1 },
                        )
                    } else {
                        Option::Some(
                            TokenAmount { token: node.pool_key.token0, amount: delta.amount0 },
                        )
                    }
            }

            token_amount =
                if (is_token1) {
                    TokenAmount { amount: -delta.amount0, token: node.pool_key.token0 }
                } else {
                    TokenAmount { amount: -delta.amount1, token: node.pool_key.token1 }
                };
        }

        let first = first_swap_amount.unwrap();
        let (input, output) = if !swap.token_amount.amount.is_negative() {
            (first, token_amount)
        } else {
            (token_amount, first)
        };

        match (input_amount) {
            Option::None => { input_amount = Option::Some(input); },
            Option::Some(mut amount) => {
                assert!(amount.token == input.token, "input-token-mismatch");
                amount.amount = amount.amount + input.amount;
                input_amount = Option::Some(amount);
            },
        }

        match (output_amount) {
            Option::None => { output_amount = Option::Some(output); },
            Option::Some(mut amount) => {
                assert!(amount.token == output.token, "output-token-mismatch");
                amount.amount = amount.amount + output.amount;
                output_amount = Option::Some(amount);
            },
        };
    }

    if !is_negative {
        // exact in: limit_amount is min. amount out
        assert!(output_amount.unwrap().amount.mag >= limit_amount, "limit-amount-not-met");
    } else {
        // exact out: limit_amount is max. amount in
        assert!(input_amount.unwrap().amount.mag <= limit_amount, "limit-amount-exceeded");
    }

    (input_amount.unwrap(), output_amount.unwrap())
}
