pub mod liquidate;
pub mod managed_vault;
pub mod multiply;
pub mod multiply4626;
pub mod proxy;
pub mod rebalance;
pub mod swap;
pub mod utils {
    pub mod position_list;
}
use ekubo::types::i129::i129;

pub fn i129_new(mag: u128, sign: bool) -> i129 {
    i129 { mag, sign: sign & (mag != 0) }
}
