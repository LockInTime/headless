//! JSON value model. `serde_json::Value` already has the right shape
//! (numbers, strings, bools, arrays, objects, null), so this module only
//! adds the typed accessors the Swift `JSONValue` exposes.

use serde_json::Value;

pub type JsonValue = Value;

pub trait JsonValueAccessors {
    fn string_value(&self) -> Option<&str>;
    fn number_value(&self) -> Option<f64>;
    fn bool_value(&self) -> Option<bool>;
}

impl JsonValueAccessors for JsonValue {
    fn string_value(&self) -> Option<&str> {
        self.as_str()
    }

    fn number_value(&self) -> Option<f64> {
        self.as_f64()
    }

    fn bool_value(&self) -> Option<bool> {
        self.as_bool()
    }
}
