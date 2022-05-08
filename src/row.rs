use glib::subclass::prelude::*;
use gtk::glib;

use crate::tas_log::{CommandFrame, PhysicsFrame};

#[derive(Debug, Clone)]
pub struct RowData {
    pub physics_frame: PhysicsFrame,
    pub command_frame: Option<CommandFrame>,
}

mod imp {
    use once_cell::unsync::OnceCell;

    use super::*;

    #[derive(Debug, Default)]
    pub struct Row {
        pub data: OnceCell<RowData>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for Row {
        const NAME: &'static str = "TlrRow";
        type Type = super::Row;
        type ParentType = glib::Object;
    }

    impl ObjectImpl for Row {}
}

glib::wrapper! {
    pub struct Row(ObjectSubclass<imp::Row>);
}

impl Row {
    pub fn new(data: RowData) -> Self {
        let obj: Self = glib::Object::new(&[]).unwrap();
        obj.imp().data.set(data).unwrap();
        obj
    }

    pub fn data(&self) -> &RowData {
        self.imp().data.get().unwrap()
    }

    pub fn physics_frame(&self) -> &PhysicsFrame {
        &self.data().physics_frame
    }

    pub fn command_frame(&self) -> Option<&CommandFrame> {
        self.data().command_frame.as_ref()
    }
}
