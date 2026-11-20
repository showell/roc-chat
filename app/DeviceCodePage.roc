## This module builds the page a signed-in human makes a device code on,
## `/devices`, which `DeviceCodeRoute` serves, and the events their pages
## hear when a code signs a new device in. The page says what became of the
## last code, offers a button that makes a new one, and, once one is made,
## shows it, with when it expires, the warning that nobody will ever ask for
## it, and a button that cancels it. app/devices.js shows each time in the
## viewer's own zone, counts the code's minutes down, hears on the viewer's
## stream that it was used, and takes the code off the page when the page
## is left.
import DateTime
import DeviceCode
import DeviceSignIns
import Escape
import Html
import PageContract
import PageKit
import Script
import ServerSentEvent
import SignedIn
import Timestamp
import TrustedHtml

DeviceCodePage :: [].{

	## Where the page is, which the top bar links to.
	path : Str
	path = PageKit.devices_path

	## Where a shown code is cancelled.
	cancel_path : Str
	cancel_path = "${PageKit.devices_path}/cancel"

	## Where every other device of the viewer's is signed out.
	sign_out_others_path : Str
	sign_out_others_path = "${PageKit.devices_path}/sign-out-others"

	## Where the page's stream is: the viewer's own events.
	stream_path : Str
	stream_path = "${PageKit.devices_path}/stream"

	## What the page shows: a code just made, with its expiry, or what the
	## record of the last one says.
	Shown : [Made({ code : DeviceCode.Code, expires : Timestamp }), Status(DeviceCode.Status)]

	## The page for `viewer`, showing `shown`.
	page : {
		viewer : SignedIn,
		shown : DeviceCodePage.Shown,
		sign_ins : List(DeviceSignIns.SignIn),
	} -> TrustedHtml
	page = |{ viewer, shown, sign_ins }| {
		full_session = viewer.check_full_session().is_ok()
		buttons_or = |made|
			if full_session {
				made
			} else {
				TrustedHtml.join([])
			}
		said =
			match shown {
				Made({ code, expires }) =>
					TrustedHtml.join([
						PageKit.paragraph("Type this code on your other device, under \"Have a code from your other device?\" on its sign-in page:"),
						shown_code(code),
						sentence([
							Escape.text("It works once, until "),
							expiry_time(expires),
							Escape.text("."),
						]),
						PageKit.paragraph(DeviceCodePage.warning_words),
						status_line(Escape.text("Waiting for your other device.")),
						buttons_or(cancel_button),
					])
				Status(Waiting(expires)) =>
					TrustedHtml.join([
						status_line(
							TrustedHtml.join([
								Escape.text("A code is waiting to be used, until "),
								expiry_time(expires),
								Escape.text(". It is shown only once; make a new code to see one."),
							]),
						),
						buttons_or(cancel_button),
					])
				Status(status) => status_line(status_words(status))
			}
		PageKit.signed_in_page({
			title: "Sign in another device",
			viewer,
			parts: [
				PageKit.paragraph("A code from here signs your phone, or any other device, in as you, with no password."),
				said,
				if full_session {
					TrustedHtml.join([
						PageKit.post_button({ action: DeviceCodePage.path, label: "Make a code" }),
						PageKit.paragraph("Making a code cancels the one before. Signing out cancels it too."),
					])
				} else {
					PageKit.paragraph(DeviceCodePage.code_session_words)
				},
				PageKit.heading("Sign-ins by code"),
				sign_ins_list(sign_ins),
				PageKit.heading("Your other devices"),
				buttons_or(
					TrustedHtml.join([
						PageKit.paragraph("If a device you don't know signed in, sign every other device out. This one stays signed in."),
						sign_out_others_button,
					]),
				),
				PageKit.script(Script.Devices),
			],
		})
	}

	## What a device whose session a code started sees in place of the
	## page's buttons.
	code_session_words : Str
	code_session_words = "This device signed in with a code, so it can't make codes or sign other devices out. Sign out here, then sign in with your password or GitHub for that."

	## What the page says beside every code it shows.
	warning_words : Str
	warning_words = "Type this only into your own device. Nobody will ever ask you for it."

	## The event that tells a human, on their own stream, that a code of
	## theirs signed a new device in: `notice`, its data a link to the page.
	new_device_frame : List(U8)
	new_device_frame =
		ServerSentEvent.named_event({
			name: "notice",
			html: Html.element({
				name: A,
				attributes: [
					LinkToPart({
						path: PageKit.site_path(DeviceCodePage.path),
						part: sign_out_others_part,
					}),
				],
				inner: Escape.text(new_device_words),
			}),
		})

	## The event that tells the device code page, on the viewer's stream,
	## that their code was used at `at`: `device-used`, its data the moment.
	used_frame : Timestamp -> List(U8)
	used_frame = |at| ServerSentEvent.named_event({
		name: "device-used",
		html: Escape.text(time_words(at)),
	})
}

## What the notice of a new device says, linked to the button that signs
## every other device out.
new_device_words : Str
new_device_words = "A new device signed in as you, with a code you made. Not you? Sign your other devices out."

## The id of the form that signs every other device out, which the notice
## of a new device links to.
sign_out_others_part : Html.Token
sign_out_others_part = PageKit.token("sign-out-others")

## The form that signs every other device of the viewer's out.
sign_out_others_button : TrustedHtml
sign_out_others_button =
	TrustedHtml.join([
		Html.element({
			name: Form,
			attributes: [
				Id(sign_out_others_part),
				MethodPost,
				Action(PageKit.site_path(DeviceCodePage.sign_out_others_path)),
			],
			inner: Html.element({
				name: Button,
				attributes: [],
				inner: Escape.text("Sign out other devices"),
			}),
		}),
		PageKit.newline,
	])

## The viewer's last sign-ins by code, newest first, each when and from
## what; or a line saying there are none.
sign_ins_list : List(DeviceSignIns.SignIn) -> TrustedHtml
sign_ins_list = |sign_ins|
	if sign_ins.is_empty() {
		PageKit.paragraph("No device has signed in with a code yet.")
	} else {
		items = sign_ins.map(
			|{ at, device }|
				Html.element({
					name: Li,
					attributes: [],
					inner: Escape.text("${time_words(at)}: ${DeviceSignIns.device_words(device)}"),
				}),
		)
		TrustedHtml.join([
			Html.element({
				name: Ul,
				attributes: [],
				inner: TrustedHtml.join(items),
			}),
			PageKit.newline,
		])
	}

## The code, large, in the class panel.js styles it by.
shown_code : DeviceCode.Code -> TrustedHtml
shown_code = |code|
	TrustedHtml.join([
		Html.element({
			name: P,
			attributes: [PageContract.class(SignInCode)],
			inner: Escape.text(code.display_text()),
		}),
		PageKit.newline,
	])

## A paragraph of `parts`, and a line end.
sentence : List(TrustedHtml) -> TrustedHtml
sentence = |parts|
	TrustedHtml.join([
		Html.element({
			name: P,
			attributes: [],
			inner: TrustedHtml.join(parts),
		}),
		PageKit.newline,
	])

## The line app/devices.js rewrites when the viewer's stream says the code
## was used, holding `inner`, and naming the stream.
status_line : TrustedHtml -> TrustedHtml
status_line = |inner|
	TrustedHtml.join([
		Html.element({
			name: P,
			attributes: [
				PageContract.class(CodeStatus),
				PageContract.data_attribute(Stream(PageKit.site_path(DeviceCodePage.stream_path))),
			],
			inner,
		}),
		PageKit.newline,
	])

## The button that cancels the code shown or waiting.
cancel_button : TrustedHtml
cancel_button = PageKit.post_button({
	action: DeviceCodePage.cancel_path,
	label: "Cancel this code",
})

## When a code expires, which app/devices.js shows in the viewer's zone and
## counts down to.
expiry_time : Timestamp -> TrustedHtml
expiry_time = |moment|
	match DateTime.from_timestamp(moment) {
		Ok(time) =>
			Html.element({
				name: Time,
				attributes: [PageContract.class(CodeExpiry), DateTime(time)],
				inner: Escape.text(time.to_str()),
			})
		Err(OutOfRange) => Escape.text(time_words(moment))
	}

## What the page says of the last code's `status`.
status_words : DeviceCode.Status -> TrustedHtml
status_words = |status|
	match status {
		NoCode => Escape.text("You have made no code yet.")
		Waiting(expires) => TrustedHtml.join([
			Escape.text("A code is waiting until "),
			expiry_time(expires),
		])
		Used(at) => Escape.text("Your last code signed a device in at ${time_words(at)}.")
		Expired => Escape.text("Your last code expired unused.")
		Cancelled => Escape.text("Your last code was cancelled.")
	}

## `moment` as a transcript writes one, or its seconds when it is out of a
## date's range.
time_words : Timestamp -> Str
time_words = |moment|
	match DateTime.from_timestamp(moment) {
		Ok(time) => time.to_str()
		Err(OutOfRange) => "${moment.to_str()} seconds"
	}
