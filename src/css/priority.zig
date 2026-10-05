//! Cascade ordering without truncating stylesheet source order.
pub const Origin = enum(u8) { ua, author, inline_ };

pub fn key(important: bool, origin: Origin, layer_order: u16, specificity: u32, source_order: u32) u128 {
    // UA !important outranks author (including inline) !important. Inline is
    // otherwise stronger than author sheets. Only layer order is reversed by
    // !important; specificity and source order still increase normally.
    const origin_order: u8 = switch (origin) {
        .ua => if (important) 3 else 0,
        .author => 1,
        .inline_ => 2,
    };
    const layer = if (important) 0xFFFF - layer_order else layer_order;
    return (@as(u128, @intFromBool(important)) << 87) |
        (@as(u128, origin_order) << 80) |
        (@as(u128, layer) << 64) |
        (@as(u128, specificity) << 32) |
        @as(u128, source_order);
}
