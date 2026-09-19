//! Markdown preview rendered by WebKitGTK.
//!
//! Lapce's UI is drawn by floem/wgpu, so a GTK widget cannot simply be dropped
//! into a pane. Instead a single dedicated thread runs GTK and owns one small
//! undecorated `WebKitWebView` window per preview pane. Those windows are kept
//! above the Lapce window, positioned over the pane's content area, and hidden
//! whenever the pane leaves preview mode. Only the markdown preview uses this;
//! the rest of the UI is untouched.
//!
//! Linux/X11 only: positioning relies on X11 window coordinates.

use std::{
    collections::HashMap,
    ffi::CStr,
    sync::{
        OnceLock,
        atomic::{AtomicU64, Ordering},
    },
    thread,
    time::Duration,
};

use crossbeam_channel::{Receiver, Sender, TryRecvError};
use gtk::prelude::*;
use webkit2gtk::WebViewExt;

use crate::config::{LapceConfig, color::LapceColor};

/// Colours the preview HTML is themed with, taken from the active theme.
pub struct PreviewColors {
    pub bg: String,
    pub text: String,
    pub dim: String,
    pub accent: String,
    pub border: String,
    pub heading: String,
    pub bold: String,
    pub italic: String,
    pub comment: String,
    pub code_bg: String,
    pub code_block_bg: String,
    pub code_block_text: String,
    pub table_header_bg: String,
    pub table_alt_bg: String,
    pub selection: String,
    pub scrollbar: String,
}

fn css_color(color: floem::peniko::Color) -> String {
    let rgba = color.to_rgba8();
    if rgba.a == 255 {
        format!("#{:02x}{:02x}{:02x}", rgba.r, rgba.g, rgba.b)
    } else {
        format!(
            "rgba({},{},{},{:.3})",
            rgba.r,
            rgba.g,
            rgba.b,
            rgba.a as f32 / 255.0
        )
    }
}

impl PreviewColors {
    pub fn from_config(config: &LapceConfig) -> Self {
        let c = |name: &str| css_color(config.color(name));
        Self {
            bg: c(LapceColor::EDITOR_BACKGROUND),
            text: c(LapceColor::EDITOR_FOREGROUND),
            dim: c(LapceColor::EDITOR_DIM),
            accent: c(LapceColor::EDITOR_LINK),
            border: c(LapceColor::LAPCE_BORDER),
            heading: c(LapceColor::EDITOR_FOREGROUND),
            bold: c(LapceColor::EDITOR_FOREGROUND),
            italic: c(LapceColor::EDITOR_DIM),
            comment: c(LapceColor::MARKDOWN_BLOCKQUOTE),
            // Inline code uses the editor background slightly darkened, the
            // fenced block keeps the md project's fixed "console" colours.
            code_bg: c(LapceColor::EDITOR_CURRENT_LINE),
            code_block_bg: "#20303b".to_string(),
            code_block_text: "#7fd57e".to_string(),
            table_header_bg: c(LapceColor::EDITOR_CURRENT_LINE),
            table_alt_bg: c(LapceColor::EDITOR_BACKGROUND),
            selection: c(LapceColor::EDITOR_SELECTION),
            scrollbar: c(LapceColor::LAPCE_SCROLL_BAR),
        }
    }

    pub fn variables(&self) -> String {
        format!(
            ":root{{--bg:{bg};--text:{text};--dim:{dim};--accent:{accent};\
             --border:{border};--heading:{heading};--bold:{bold};--italic:{italic};\
             --comment:{comment};--code-bg:{code_bg};--code-block-bg:{block_bg};\
             --code-block-text:{block_text};--table-header-bg:{th};--table-alt-bg:{alt};\
             --selection-color:{sel};--scrollbar-bg:{sb};}}",
            bg = self.bg,
            text = self.text,
            dim = self.dim,
            accent = self.accent,
            border = self.border,
            heading = self.heading,
            bold = self.bold,
            italic = self.italic,
            comment = self.comment,
            code_bg = self.code_bg,
            block_bg = self.code_block_bg,
            block_text = self.code_block_text,
            th = self.table_header_bg,
            alt = self.table_alt_bg,
            sel = self.selection,
            sb = self.scrollbar,
        )
    }
}

const PREVIEW_CSS: &str = include_str!("markdown_preview.css");

/// Keep the scroll position across the document reloads that follow edits.
const SCROLL_SCRIPT: &str = r#"
(function () {
  window.addEventListener('scroll', function () {
    try { window.name = String(window.scrollY); } catch (e) {}
  }, { passive: true });
  document.addEventListener('DOMContentLoaded', function () {
    var y = parseFloat(window.name || '0');
    if (y > 0) { window.scrollTo(0, y); }
  });
})();
"#;

/// Convert markdown to a self-contained HTML document for the WebKit view.
///
/// Raw HTML in the source is dropped rather than passed through, so a document
/// cannot inject markup or scripts into the preview.
pub fn build_html(markdown: &str, colors: &PreviewColors) -> String {
    use pulldown_cmark::{Event, Options, Parser, html};

    let parser = Parser::new_ext(
        markdown,
        Options::ENABLE_TABLES
            | Options::ENABLE_FOOTNOTES
            | Options::ENABLE_STRIKETHROUGH
            | Options::ENABLE_TASKLISTS,
    )
    .filter(|event| {
        !matches!(
            event,
            Event::Html(_) | Event::InlineHtml(_) | Event::InlineMath(_)
        )
    });
    let mut body = String::new();
    html::push_html(&mut body, parser);

    format!(
        "<!doctype html><html><head><meta charset=\"utf-8\"><style>{vars}{css}</style>\
         </head><body><div id=\"preview\"><div class=\"markdown-body\">{body}</div></div>\
         <script>{script}</script></body></html>",
        vars = colors.variables(),
        css = PREVIEW_CSS,
        body = body,
        script = SCROLL_SCRIPT,
    )
}

/// Called when the preview is clicked, so the owning pane becomes active.
pub type Activate = std::sync::Arc<dyn Fn() + Send + Sync>;

enum Cmd {
    Create(u64, Activate),
    Destroy(u64),
    Bounds(u64, i32, i32, i32, i32),
    Html(u64, String),
    Visible(u64, bool),
}

struct Manager {
    tx: Sender<Cmd>,
    next_id: AtomicU64,
    available: bool,
}

static MANAGER: OnceLock<Manager> = OnceLock::new();

fn manager() -> &'static Manager {
    MANAGER.get_or_init(|| {
        let (tx, rx) = crossbeam_channel::unbounded();
        let (ready_tx, ready_rx) = crossbeam_channel::bounded(1);
        let available = thread::Builder::new()
            .name("webkit-preview".into())
            .spawn(move || gtk_main(rx, ready_tx))
            .ok()
            .and_then(|_| ready_rx.recv().ok())
            .unwrap_or(false);
        Manager {
            tx,
            next_id: AtomicU64::new(1),
            available,
        }
    })
}

/// A handle to one WebKit preview window.
pub struct WebkitPreview {
    id: u64,
    tx: Sender<Cmd>,
}

impl WebkitPreview {
    /// Create a preview window, or `None` when WebKitGTK is unavailable.
    ///
    /// `activate` is invoked when the preview is clicked, so the app can make
    /// the owning editor pane the active one (the click goes to the WebKit
    /// window, so floem never sees it).
    pub fn spawn(activate: impl Fn() + Send + Sync + 'static) -> Option<Self> {
        let manager = manager();
        if !manager.available {
            return None;
        }
        let id = manager.next_id.fetch_add(1, Ordering::Relaxed);
        manager
            .tx
            .send(Cmd::Create(id, std::sync::Arc::new(activate)))
            .ok()?;
        Some(Self {
            id,
            tx: manager.tx.clone(),
        })
    }

    pub fn set_html(&self, html: String) {
        let _ = self.tx.send(Cmd::Html(self.id, html));
    }

    pub fn set_bounds(&self, x: f64, y: f64, width: f64, height: f64) {
        let _ = self.tx.send(Cmd::Bounds(
            self.id,
            x.round() as i32,
            y.round() as i32,
            width.max(1.0).round() as i32,
            height.max(1.0).round() as i32,
        ));
    }

    pub fn set_visible(&self, visible: bool) {
        let _ = self.tx.send(Cmd::Visible(self.id, visible));
    }
}

impl Drop for WebkitPreview {
    fn drop(&mut self) {
        let _ = self.tx.send(Cmd::Destroy(self.id));
    }
}

struct PreviewWindow {
    window: gtk::Window,
    webview: webkit2gtk::WebView,
    visible: bool,
    /// X11 window id, used to raise the preview above the Lapce window.
    xid: Option<x11_dl::xlib::Window>,
}

impl PreviewWindow {
    fn apply_visible(&mut self, x11: Option<&ParentWindow>) {
        if self.visible {
            // `show_all` maps the window without raising/focusing it, so the
            // editor keeps keyboard focus when a pane enters preview mode.
            self.window.show_all();
            // Map it above the Lapce window. Without a transient-for hint a
            // compositing WM (Mutter) can leave it stacked behind, which looks
            // like an empty preview pane.
            if let (Some(parent), Some(xid)) = (x11, self.xid) {
                unsafe { parent.raise(xid) };
            }
        } else {
            self.window.hide();
        }
    }
}

fn gtk_main(rx: Receiver<Cmd>, ready: Sender<bool>) -> bool {
    if gtk::init().is_err() {
        let _ = ready.send(false);
        return false;
    }

    // Position is relative to the Lapce window; resolve its screen origin once.
    let x11 = unsafe { ParentWindow::discover() };

    let mut windows: HashMap<u64, PreviewWindow> = HashMap::new();

    {
        let main_loop = gtk::glib::MainLoop::new(None, false);
        let quit_loop = main_loop.clone();
        gtk::glib::timeout_add_local(Duration::from_millis(16), move || {
            loop {
                match rx.try_recv() {
                    Ok(Cmd::Create(id, activate)) => {
                        if let Some(window) = create_window(x11.as_ref(), activate) {
                            windows.insert(id, window);
                        }
                    }
                    Ok(Cmd::Destroy(id)) => {
                        if let Some(window) = windows.remove(&id) {
                            unsafe { window.window.destroy() };
                        }
                    }
                    Ok(Cmd::Bounds(id, x, y, w, h)) => {
                        if let Some(window) = windows.get_mut(&id) {
                            let (ox, oy) = x11
                                .as_ref()
                                .map(|p| (p.origin_x, p.origin_y))
                                .unwrap_or((0, 0));
                            window.window.move_(ox + x, oy + y);
                            window.window.resize(w, h);
                            if let (Some(parent), Some(xid)) =
                                (x11.as_ref(), window.xid)
                            {
                                unsafe { parent.raise(xid) };
                            }
                        }
                    }
                    Ok(Cmd::Html(id, html)) => {
                        if let Some(window) = windows.get_mut(&id) {
                            window.webview.load_html(&html, None);
                        }
                    }
                    Ok(Cmd::Visible(id, visible)) => {
                        if let Some(window) = windows.get_mut(&id) {
                            window.visible = visible;
                            window.apply_visible(x11.as_ref());
                        }
                    }
                    Err(TryRecvError::Empty) => break,
                    Err(TryRecvError::Disconnected) => {
                        quit_loop.quit();
                        return gtk::glib::ControlFlow::Break;
                    }
                }
            }
            gtk::glib::ControlFlow::Continue
        });
        let _ = ready.send(true);
        main_loop.run();
    }

    true
}

fn create_window(
    parent: Option<&ParentWindow>,
    activate: Activate,
) -> Option<PreviewWindow> {
    let window = gtk::Window::new(gtk::WindowType::Toplevel);
    window.set_decorated(false);
    window.set_resizable(false);
    window.set_skip_taskbar_hint(true);
    window.set_skip_pager_hint(true);
    window.set_accept_focus(true);
    window.set_type_hint(gtk::gdk::WindowTypeHint::Utility);
    window.set_default_size(1, 1);

    let webview = webkit2gtk::WebView::new();
    webview.set_hexpand(true);
    webview.set_vexpand(true);
    {
        // A click lands on the WebKit window, not on floem, so tell the app to
        // make this pane active. Returning `Inhibit(false)` lets WebKit handle
        // the click as usual (selection, scrolling, links).
        let activate = activate.clone();
        webview.connect_button_press_event(move |_, _| {
            activate();
            gtk::glib::Propagation::Proceed
        });
    }
    window.add(&webview);

    // Realise the GDK window first so its X11 window id exists; a
    // transient-for hint then keeps the preview above the Lapce window and
    // moving with it.
    window.show_all();
    let xid = window.window().and_then(|gdk_window| gdk_xid(&gdk_window));
    if let Some(parent) = parent {
        if xid.is_some() {
            // Go through GDK rather than a raw `XSetTransientForHint`: only GDK
            // remembers the hint, and it re-applies it when the window is
            // mapped again after being hidden (which is what toggling Preview
            // does).
            mark_transient(&window, parent.window);
            window.move_(parent.origin_x, parent.origin_y);
        }
    }

    let mut window = PreviewWindow {
        window,
        webview,
        // Hidden until the pane reports its bounds and asks for the preview.
        visible: false,
        xid,
    };
    window.apply_visible(parent);
    Some(window)
}

/// The X11 window id behind a realised GDK window.
fn gdk_xid(gdk_window: &gtk::gdk::Window) -> Option<x11_dl::xlib::Window> {
    use gtk::glib::translate::ToGlibPtr;
    let ptr: *mut gtk::gdk::ffi::GdkWindow = gdk_window.to_glib_none().0;
    if ptr.is_null() {
        return None;
    }
    let xid = unsafe {
        gdkx11::ffi::gdk_x11_window_get_xid(ptr as *mut gdkx11::ffi::GdkX11Window)
    };
    if xid == 0 {
        None
    } else {
        Some(xid as x11_dl::xlib::Window)
    }
}

/// Mark the preview window as transient for the Lapce window.
///
/// This keeps the preview stacked above the editor and moving with it on a
/// compositing window manager such as Mutter.
fn mark_transient(window: &gtk::Window, parent_xid: x11_dl::xlib::Window) {
    let Some(gdk_window) = window.window() else {
        return;
    };
    let Some(display) = gtk::gdk::Display::default() else {
        return;
    };
    let Ok(x11_display) = display.downcast::<gdkx11::X11Display>() else {
        return;
    };
    let parent =
        gdkx11::X11Window::foreign_new_for_display(&x11_display, parent_xid as _);
    gdk_window.set_transient_for(parent.upcast_ref::<gtk::gdk::Window>());
}

/// The Lapce X11 window, found by its `WM_CLASS`, plus its screen origin.
struct ParentWindow {
    display: *mut x11_dl::xlib::Display,
    window: x11_dl::xlib::Window,
    origin_x: i32,
    origin_y: i32,
}

impl ParentWindow {
    #[allow(unsafe_op_in_unsafe_fn)]
    unsafe fn discover() -> Option<Self> {
        let xlib = x11_dl::xlib::Xlib::open().ok()?;
        let display = (xlib.XOpenDisplay)(std::ptr::null());
        if display.is_null() {
            return None;
        }
        let root = (xlib.XDefaultRootWindow)(display);

        let mut root_ret = 0;
        let mut parent_ret = 0;
        let mut children: *mut x11_dl::xlib::Window = std::ptr::null_mut();
        let mut count: u32 = 0;
        if (xlib.XQueryTree)(
            display,
            root,
            &mut root_ret,
            &mut parent_ret,
            &mut children,
            &mut count,
        ) == 0
        {
            (xlib.XCloseDisplay)(display);
            return None;
        }

        let mut found = None;
        for i in 0..count {
            let candidate = *children.add(i as usize);
            let mut hint = x11_dl::xlib::XClassHint {
                res_name: std::ptr::null_mut(),
                res_class: std::ptr::null_mut(),
            };
            if (xlib.XGetClassHint)(display, candidate, &mut hint) != 0 {
                let name = if hint.res_name.is_null() {
                    String::new()
                } else {
                    CStr::from_ptr(hint.res_name).to_string_lossy().into_owned()
                };
                if !hint.res_name.is_null() {
                    (xlib.XFree)(hint.res_name as *mut _);
                }
                if !hint.res_class.is_null() {
                    (xlib.XFree)(hint.res_class as *mut _);
                }
                if name == "lapce" {
                    found = Some(candidate);
                    break;
                }
            }
        }
        if !children.is_null() {
            (xlib.XFree)(children as *mut _);
        }

        let window = found?;
        let mut origin_x = 0;
        let mut origin_y = 0;
        let mut child_ret = 0;
        (xlib.XTranslateCoordinates)(
            display,
            window,
            root,
            0,
            0,
            &mut origin_x,
            &mut origin_y,
            &mut child_ret,
        );

        Some(Self {
            display,
            window,
            origin_x,
            origin_y,
        })
    }

    #[allow(unsafe_op_in_unsafe_fn)]
    unsafe fn raise(&self, child: x11_dl::xlib::Window) {
        let xlib = x11_dl::xlib::Xlib::open().ok();
        if let Some(xlib) = xlib {
            (xlib.XRaiseWindow)(self.display, child);
        }
    }
}
