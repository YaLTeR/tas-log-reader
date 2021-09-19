use serde::Deserialize;

#[derive(Debug, Clone, Deserialize)]
pub struct Log {
    #[serde(rename = "pf")]
    pub physics_frames: Vec<PhysicsFrame>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct PhysicsFrame {
    #[serde(rename = "ft")]
    pub frame_time: Option<f64>,
    #[serde(rename = "cls", default = "five")]
    pub client_state: i32,
    #[serde(rename = "p", default)]
    pub is_paused: bool,
    #[serde(rename = "cbuf")]
    pub command_buffer: Option<String>,
    #[serde(rename = "cf")]
    pub command_frames: Vec<CommandFrame>,
}

fn five() -> i32 {
    5
}

#[derive(Debug, Clone, Copy, Deserialize)]
pub struct CommandFrame {
    #[serde(rename = "bid")]
    pub frame_bulk_id: Option<usize>,
    #[serde(rename = "rem")]
    pub frame_time_remainder: Option<f64>,
    #[serde(rename = "ms")]
    pub msec: u8,
    #[serde(rename = "btns")]
    pub buttons: u16,
    #[serde(rename = "impls")]
    pub impulse: Option<u8>,
    #[serde(rename = "fsu")]
    pub fsu: [f32; 3],
    #[serde(rename = "view")]
    pub view_angles: [f32; 3],
    #[serde(rename = "ss")]
    pub shared_seed: u32,
    #[serde(rename = "hp")]
    pub health: Option<f32>,
    #[serde(rename = "ap")]
    pub armor: Option<f32>,
    #[serde(rename = "efric", default = "one")]
    pub entity_friction: f32,
    #[serde(rename = "egrav", default = "one")]
    pub entity_gravity: f32,
    #[serde(rename = "pview", default)]
    pub punchangle: [f32; 3],
    #[serde(rename = "prepm")]
    pub pre_pm_state: Option<PmState>,
    #[serde(rename = "postpm")]
    pub post_pm_state: Option<PmState>,
}

fn one() -> f32 {
    1.
}

#[derive(Debug, Clone, Copy, Deserialize)]
pub struct PmState {
    #[serde(rename = "pos")]
    pub position: [f32; 3],
    #[serde(rename = "vel")]
    pub velocity: [f32; 3],
    #[serde(rename = "og")]
    pub on_ground: bool,
    #[serde(rename = "ol", default)]
    pub on_ladder: bool,
    #[serde(rename = "bvel", default)]
    pub base_velocity: [f32; 3],
    #[serde(rename = "wlvl", default)]
    pub water_level: i32,
    #[serde(rename = "dst", default)]
    pub duck_state: u8,
}
