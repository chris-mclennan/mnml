//! Small property-name-keyed vocabulary for schema-driven body
//! synthesis. Given a swagger property name like `firstName` or
//! `emailAddress`, produces a realistic placeholder value instead
//! of the naive `"string"` / `0`. Deterministic — every call for
//! the same name returns the same value so repeated syncs don't
//! churn.
//!
//! Tier 2 of the dynamic + realistic request generation roadmap
//! (2026-07-09).
//!
//! Design notes:
//! - Match is CASE-INSENSITIVE on the normalized property name
//!   (camel/snake/kebab all collapse to lowercase-alphanumeric).
//! - Multiple names can map to the same value ("firstName" /
//!   "givenName" / "first_name" all → "John").
//! - Fallback for unknown names is the existing "string" / 0 / etc.
//!   Nothing changes if no rule matches.
//! - Explicit env-var references (`{{MERCHANT_ID}}` etc.) preferred
//!   over faker values for IDs — users tune via `.mnml/env/*.env`
//!   instead of hand-editing bodies.

use serde_json::Value;

/// Return a plausible placeholder value for a schema property named
/// `prop` of the given JSON `type`. `None` when no matching rule
/// fires — caller should fall through to its existing defaults.
///
/// `ty` is the swagger `type` field (`"string"`, `"integer"`,
/// `"number"`, `"boolean"`). Rules only apply when they match a
/// compatible type — a `phoneNumber` on an `integer` field gets no
/// magic (would produce a nonsense value).
pub fn placeholder_for(prop: &str, ty: &str) -> Option<Value> {
    let normalized = normalize_key(prop);
    let key = normalized.as_str();
    match ty {
        "string" => string_placeholder(key),
        "integer" | "number" => numeric_placeholder(key),
        "boolean" => bool_placeholder(key),
        _ => None,
    }
}

fn string_placeholder(key: &str) -> Option<Value> {
    let s: &str = match key {
        // Names / people
        "firstname" | "givenname" | "fname" => "John",
        "lastname" | "familyname" | "surname" | "lname" => "Smith",
        "fullname" | "name" | "displayname" => "John Smith",
        "middlename" => "Q",
        "username" | "login" => "jsmith",
        "nickname" => "jay",

        // Contact
        "email" | "emailaddress" | "emailid" => "user@example.com",
        "phone" | "phonenumber" | "mobile" | "telephone" => "555-0100",
        "fax" | "faxnumber" => "555-0199",

        // Address
        "address" | "address1" | "streetaddress" | "street" | "line1" => "123 Main St",
        "address2" | "line2" => "Suite 100",
        "city" | "town" | "locality" => "San Francisco",
        "state" | "region" | "province" => "CA",
        "country" | "countryname" => "United States",
        "countrycode" => "US",
        "zipcode" | "postalcode" | "postcode" | "zip" => "94105",

        // Company / business
        "company" | "companyname" | "organization" | "orgname" | "business" | "businessname" => {
            "Acme Inc"
        }
        "brand" | "brandname" => "Acme",

        // Web
        "url" | "website" | "homepage" | "link" => "https://example.com",
        "domain" | "domainname" => "example.com",
        "ipaddress" | "ip" => "192.168.1.1",
        "useragent" => "Mozilla/5.0",

        // Money / commerce
        "currency" | "currencycode" => "USD",
        "sku" | "productcode" | "itemcode" => "SKU-12345",
        "productname" | "itemname" => "Menu Item",
        "orderref" | "orderreference" | "ordercode" => "ORDER-12345",

        // Language / locale
        "language" | "lang" | "languagecode" => "en",
        "locale" => "en-US",
        "timezone" | "tz" => "America/Los_Angeles",

        // Descriptors
        "description" => "Sample description",
        "comment" | "note" | "notes" | "message" | "body" | "text" => "Sample text",
        "title" | "subject" | "headline" => "Sample title",
        "slug" => "sample-slug",
        "tag" | "label" => "sample",

        // Status / kind. `"state"` already matched above (US state);
        // ordering + earlier match wins there.
        "status" => "active",
        "kind" | "type" | "category" => "default",

        // Colors
        "color" | "colour" | "hexcolor" => "#4A90E2",

        _ => return None,
    };
    Some(Value::String(s.to_string()))
}

fn numeric_placeholder(key: &str) -> Option<Value> {
    // ID-shaped fields — reference the corresponding env var so
    // users tune via `.mnml/env/dev.env` (Tier 4 territory but
    // wired in now for the common cases). Emit as a *string* value
    // so the `{{ENV_VAR}}` template renders literally in the body;
    // downstream `template::expand` substitutes at fire time.
    if let Some(name) = id_env_var(key) {
        return Some(Value::String(format!("{{{{{name}}}}}")));
    }
    let n: i64 = match key {
        "quantity" | "qty" | "count" | "size" => 1,
        "page" | "pagenumber" | "pageindex" => 1,
        "pagesize" | "perpage" | "limit" | "take" => 25,
        "offset" | "skip" => 0,
        "price" | "amount" | "total" | "subtotal" | "cost" | "value" => {
            // For decimal-ish fields, prefer a Number::from_f64
            // fallthrough. Integer fields fall through to the
            // generic `0` case since we can't tell here.
            return Some(Value::Number(
                serde_json::Number::from_f64(9.99).unwrap_or(0.into()),
            ));
        }
        "rating" | "score" | "stars" => 5,
        "year" => 2026,
        "month" => 1,
        "day" => 1,
        "hour" => 12,
        "minute" | "min" => 30,
        "second" | "sec" => 0,
        _ => return None,
    };
    Some(Value::Number(n.into()))
}

fn bool_placeholder(key: &str) -> Option<Value> {
    // Most boolean flags default to false unless the name suggests
    // "on" / "enabled" — those are conventionally true.
    let val = match key {
        "enabled" | "active" | "isactive" | "isenabled" | "on" => true,
        "disabled" | "inactive" | "deleted" | "archived" | "cancelled" | "off" => false,
        _ => return None,
    };
    Some(Value::Bool(val))
}

/// Well-known-ID → env-var mapping. Given a property or path-param
/// name, return the env-var it should reference. `None` for
/// non-ID or unknown names.
///
/// Public so discover's path templater (`render_curl`) can reuse
/// the exact same table for `{merchantId}` → `{{MERCHANT_ID}}`
/// path substitution — Tier 4 of the dynamic-realistic roadmap.
pub fn id_env_var(name: &str) -> Option<&'static str> {
    let key = normalize_key(name);
    match key.as_str() {
        "merchantid" | "restaurantid" | "storeid" => Some("MERCHANT_ID"),
        "userid" | "accountid" | "customerid" => Some("USER_ID"),
        "locationid" | "siteid" | "branchid" => Some("LOCATION_ID"),
        "surveyid" => Some("SURVEY_ID"),
        "orderid" | "transactionid" => Some("ORDER_ID"),
        "productid" | "itemid" | "menuitemid" => Some("PRODUCT_ID"),
        "brandid" => Some("BRAND_ID"),
        "questionnaireid" => Some("QUESTIONNAIRE_ID"),
        "campaignid" => Some("CAMPAIGN_ID"),
        _ => None,
    }
}

/// Return every distinct env-var name this vocab knows about.
/// Used to seed `.mnml/env/dev.env.example` so users see the
/// full menu of overridable IDs at a glance.
pub fn known_env_vars() -> Vec<&'static str> {
    let mut out = vec![
        "MERCHANT_ID",
        "USER_ID",
        "LOCATION_ID",
        "SURVEY_ID",
        "ORDER_ID",
        "PRODUCT_ID",
        "BRAND_ID",
        "QUESTIONNAIRE_ID",
        "CAMPAIGN_ID",
    ];
    out.sort();
    out
}

/// Normalize a property name to a lowercase-alphanumeric key so
/// `firstName`, `first_name`, `FirstName`, `first-name` all map
/// to the same lookup key `firstname`.
fn normalize_key(prop: &str) -> String {
    let mut out = String::with_capacity(prop.len());
    for c in prop.chars() {
        if c.is_ascii_alphanumeric() {
            out.push(c.to_ascii_lowercase());
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matches_common_string_properties() {
        assert_eq!(
            placeholder_for("firstName", "string"),
            Some(Value::String("John".into()))
        );
        assert_eq!(
            placeholder_for("first_name", "string"),
            Some(Value::String("John".into()))
        );
        assert_eq!(
            placeholder_for("FirstName", "string"),
            Some(Value::String("John".into()))
        );
        assert_eq!(
            placeholder_for("emailAddress", "string"),
            Some(Value::String("user@example.com".into()))
        );
        assert_eq!(
            placeholder_for("phoneNumber", "string"),
            Some(Value::String("555-0100".into()))
        );
    }

    #[test]
    fn id_fields_reference_env_vars() {
        assert_eq!(
            placeholder_for("merchantId", "integer"),
            Some(Value::String("{{MERCHANT_ID}}".into()))
        );
        assert_eq!(
            placeholder_for("user_id", "integer"),
            Some(Value::String("{{USER_ID}}".into()))
        );
    }

    #[test]
    fn numeric_defaults_pick_reasonable_values() {
        assert_eq!(placeholder_for("quantity", "integer"), Some(1.into()));
        assert_eq!(placeholder_for("pageSize", "integer"), Some(25.into()));
        assert_eq!(placeholder_for("rating", "integer"), Some(5.into()));
    }

    #[test]
    fn bool_flags_prefer_active_over_disabled() {
        assert_eq!(placeholder_for("enabled", "boolean"), Some(true.into()));
        assert_eq!(placeholder_for("isActive", "boolean"), Some(true.into()));
        assert_eq!(placeholder_for("archived", "boolean"), Some(false.into()));
    }

    #[test]
    fn unmatched_name_or_wrong_type_returns_none() {
        assert_eq!(placeholder_for("frobnicator", "string"), None);
        assert_eq!(placeholder_for("firstName", "integer"), None);
        assert_eq!(placeholder_for("emailAddress", "boolean"), None);
    }
}
