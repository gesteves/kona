import { EmailMessage } from 'cloudflare:email';
import { createMimeMessage } from 'mimetext';
import { requestLogLine } from './log';

// Handles the /contact form POST — the replacement for Netlify Forms, which intercepted
// this submission at the platform layer with no code of ours. The form itself is authored
// in Contentful (fields: name, email, comment [honeypot], message) and posts here; the
// Worker mails the submission via the Email Routing send_email binding and redirects to
// the same success page Netlify used.
//
// CONTACT_EMAIL_FROM must be an address on the Email Routing subdomain (that's a hard
// Cloudflare requirement — `from` has to be on a routing domain), and CONTACT_EMAIL_TO a
// verified destination address (sending to one is free on all plans). Both are dashboard
// vars, so no address lives in the repo.
//
// 🤔 Delivered mail shows as "dropped" in the Email Routing summary — outbound sends are
// tracked under Email Sending metrics. Alarming-looking, harmless.

// User input that ends up in MIME headers (Subject, Reply-To) must never contain CR/LF,
// or a submission could inject arbitrary headers into the message.
function headerSafe(value: FormDataValue | null): string {
  return (value ?? '')
    .toString()
    .replace(/[\r\n]+/g, ' ')
    .trim();
}

type FormDataValue = ReturnType<FormData['get']>;

export async function handleContact(
  request: Request,
  env: Env
): Promise<Response> {
  // 303 so the browser follows up with a GET; /contact/success is a real static page.
  const success = new URL('/contact/success', request.url).toString();
  const redirect = () => Response.redirect(success, 303);

  let form: FormData;
  try {
    form = await request.formData();
  } catch {
    return new Response('Bad request', { status: 400 });
  }

  // The honeypot: a real visitor never fills "comment" (it's visually hidden; the visible
  // field is "message"). Return the same redirect a real submission gets, so a bot learns
  // nothing from the response.
  if (headerSafe(form.get('comment')).length > 0) {
    console.info(requestLogLine(request, 'POST /contact', '→ honeypot'));
    return redirect();
  }

  const name = headerSafe(form.get('name'));
  const email = headerSafe(form.get('email'));
  const message = (form.get('message') ?? '').toString().trim();

  // Nothing to send — treat like success rather than surfacing an error page for what is
  // almost always a double-submit or a bot that skipped the fields.
  if (!message) return redirect();

  if (!env.CONTACT_EMAIL_FROM || !env.CONTACT_EMAIL_TO) {
    console.error(
      'Contact form misconfigured: CONTACT_EMAIL_FROM/CONTACT_EMAIL_TO unset'
    );
    return new Response('Service unavailable', { status: 503 });
  }

  const mime = createMimeMessage();
  mime.setSender({
    name: name || 'Contact form',
    addr: env.CONTACT_EMAIL_FROM,
  });
  mime.setRecipient(env.CONTACT_EMAIL_TO);
  mime.setSubject(name ? `Contact form: ${name}` : 'Contact form submission');
  // Reply-To the visitor, so answering the notification mail just works.
  if (email) mime.setHeader('Reply-To', email);
  mime.addMessage({
    contentType: 'text/plain',
    data: [
      `Name: ${name || '(not given)'}`,
      `Email: ${email || '(not given)'}`,
      '',
      message,
    ].join('\n'),
  });

  try {
    await env.EMAIL.send(
      new EmailMessage(
        env.CONTACT_EMAIL_FROM,
        env.CONTACT_EMAIL_TO,
        mime.asRaw()
      )
    );
  } catch (error) {
    console.error('Contact form send failed:', error);
    return new Response('Sending failed — please try again.', { status: 500 });
  }

  console.info(requestLogLine(request, 'POST /contact', '→ sent'));
  return redirect();
}
