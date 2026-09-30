// Local HTML only. Pass exported {x,ig} JSScripts JSON as argv[2]. Requires jsdom.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const {JSDOM} = require('jsdom');
const scripts = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
function extract(key, html, path = '/') {
  const dom = new JSDOM(html, {url: `https://${key.startsWith('x') ? 'x.com' : 'www.instagram.com'}${path}`, runScripts: 'outside-only'});
  dom.window.HTMLElement.prototype.getClientRects = function () {return this.hidden ? [] : [{width: 100, height: 20}];};
  return JSON.parse(dom.window.eval(scripts[key]));
}
const following = '<div role="tab" aria-selected="true">Following</div>';
const tweet = (id, content, extra = '') => `<article data-testid="tweet"><div data-testid="User-Name"><a href="/tester">Test Author</a></div><a href="/tester/status/${id}"><time datetime="2026-03-05T10:00:00Z"></time></a>${content}${extra}</article>`;
let value = extract('x', following + tweet('123', '<div data-testid="tweetText">A real update</div>', '<button data-testid="like" aria-label="1.2K Likes"></button>'));
assert.equal(value.status, 'ready'); assert.equal(value.posts[0].id, '123'); assert.equal(value.posts[0].likes, 1200);
assert.equal(value.posts[0].author, 'Test Author');
assert.equal(extract('x', following + tweet('130', '<div data-testid="tweetText">Something went wrong with my coffee</div>')).status, 'ready');
value = extract('x', following + tweet('124', '<div data-testid="tweetPhoto"><img alt="A cat in a sunbeam"></div>'));
assert.match(value.posts[0].text, /cat/);
value = extract('x', following + tweet('125', '<div data-testid="tweetText">Sponsored card</div>', '<span>Promoted</span>'));
assert.equal(value.status, 'loading'); assert.equal(value.posts.length, 0);
value = extract('x', following + '<article><div data-testid="tweetText">No permalink</div></article>');
assert.equal(value.posts.length, 0); assert.equal(value.emptyConfirmed, false);
assert.equal(extract('x', '<div role="tab" aria-selected="false">Following</div>' + tweet('126', '<div data-testid="tweetText">For You content</div>')).status, 'loading');
assert.equal(extract('x', '<input autocomplete="username">', '/i/flow/login').status, 'loginRequired');
assert.equal(extract('x', '<main>Loading login</main>', '/i/jf/onboarding/web?mode=login').status, 'loginRequired');
assert.equal(extract('x', following + '<div>Your timeline is empty</div>').emptyConfirmed, true);
value = extract('ig', '<article><header><a href="/photographer/">Photographer</a><img alt="Profile picture"></header><a href="/p/Abc_123/"><time datetime="2026-03-05T10:00:00.000Z"></time></a><h1>A short caption</h1><img alt="Mountain at dusk"></article>');
assert.equal(value.status, 'ready'); assert.equal(value.posts[0].id, 'Abc_123'); assert.equal(value.posts[0].handle, 'photographer'); assert.match(value.posts[0].text, /Mountain/); assert.doesNotMatch(value.posts[0].text, /Profile picture/);
value = extract('ig', '<article><a href="/reel/Video_1/"><time></time></a><video></video></article>');
assert.equal(value.posts[0].id, 'Video_1'); assert.equal(value.posts[0].text, '[Video post]');
assert.equal(extract('ig', '<article><img alt="No permalink"></article>').status, 'loading');
assert.equal(extract('ig', '<input name="password">', '/accounts/login/').status, 'loginRequired');
assert.equal(extract('ig', '<button>Continue saved_profile</button><button>Use another profile</button>').status, 'loginRequired');
assert.equal(extract('ig', '<div>Verify</div>', '/challenge/').status, 'loginRequired');
assert.equal(extract('ig', '<div>Couldn’t refresh feed</div>').status, 'error');

// Actual attachments, including media-only posts and multiple carousel slides.
value = extract('x', following + tweet('140', '<div data-testid="tweetPhoto"><img src="https://pbs.twimg.com/media/photo1.jpg" alt="First photo" width="800" height="600"></div><div data-testid="tweetPhoto"><img srcset="https://pbs.twimg.com/media/photo2-small.jpg 320w, https://pbs.twimg.com/media/photo2.jpg 1200w" alt="Second photo"></div><div data-testid="Tweet-User-Avatar"><img src="https://pbs.twimg.com/profile_images/avatar.jpg" alt="Avatar"></div>'));
assert.equal(value.status, 'ready'); assert.equal(value.posts[0].media.length, 2);
assert.equal(value.posts[0].media[0].kind, 'image'); assert.equal(value.posts[0].media[0].width, 800);
assert.equal(value.posts[0].media[1].url, 'https://pbs.twimg.com/media/photo2.jpg');
assert.equal(value.diagnostics.articles, 1); assert.equal(value.diagnostics.images, 3); assert.equal(value.diagnostics.attachments, 2);
value = extract('x', following + tweet('141', '<div data-testid="videoPlayer"><video src="blob:https://x.com/private-session" poster="https://pbs.twimg.com/media/poster.jpg" width="1280" height="720"></video><img src="https://pbs.twimg.com/media/poster.jpg"></div>'));
assert.equal(value.posts[0].media.length, 1); assert.equal(value.posts[0].media[0].kind, 'video');
assert.equal(value.posts[0].media[0].url, null); assert.match(value.posts[0].media[0].previewURL, /poster/);
value = extract('ig', '<article><a href="/photographer/"><img src="https://scontent.cdninstagram.com/avatar.jpg" width="150" height="150"></a><a href="/p/Carousel1/"><time></time></a><img src="https://scontent.cdninstagram.com/slide1.jpg" alt="Slide one" width="1080" height="1080"><img src="https://scontent.cdninstagram.com/slide2.jpg" alt="Slide two" width="1080" height="1080"><img src="https://scontent.cdninstagram.com/icon.png" alt="Like" width="24" height="24"></article>');
assert.equal(value.status, 'ready'); assert.equal(value.posts[0].media.length, 2);
assert.equal(value.posts[0].media[0].altText, 'Slide one');
value = extract('ig', '<article><a href="/reel/Video2/"><time></time></a><video poster="https://scontent.cdninstagram.com/poster.jpg"><source src="https://scontent.cdninstagram.com/video.mp4" type="video/mp4"></video></article>');
assert.equal(value.posts[0].media[0].kind, 'video'); assert.match(value.posts[0].media[0].url, /video.mp4$/);
assert.match(value.posts[0].media[0].previewURL, /poster.jpg$/);

value = extract('x', following + tweet('142', '<div data-testid="tweetPhoto"><img src="https://pbs.twimg.com/media/photo-first.jpg" alt="First"></div><div data-testid="videoPlayer"><img src="https://pbs.twimg.com/media/video-poster.jpg?name=small"><video src="https://video.twimg.com/video-middle.mp4" poster="https://pbs.twimg.com/media/video-poster.jpg?name=large"></video></div><div data-testid="tweetPhoto"><img src="https://pbs.twimg.com/media/photo-last.jpg" alt="Last"></div>'));
assert.deepEqual(value.posts[0].media.map(item => item.kind), ['image', 'video', 'image']);
assert.match(value.posts[0].media[0].url, /photo-first/); assert.match(value.posts[0].media[2].url, /photo-last/);
assert.equal(value.posts[0].media.length, 3, 'The video poster must not become a fourth carousel slide');
value = extract('ig', '<article><a href="/p/MixedCarousel/"><time></time></a><img src="https://scontent.cdninstagram.com/first.jpg" alt="First"><video src="https://scontent.cdninstagram.com/middle.mp4" poster="https://scontent.cdninstagram.com/middle.jpg"></video><img src="https://scontent.cdninstagram.com/last.jpg" alt="Last"></article>');
assert.deepEqual(value.posts[0].media.map(item => item.kind), ['image', 'video', 'image']);
assert.match(value.posts[0].media[0].url, /first.jpg$/); assert.match(value.posts[0].media[2].url, /last.jpg$/);

value = extract('ig', '<article><a href="/reel/AudioCaption/"><time></time></a><a href="/reels/audio/123/"><span dir="auto">Mix: Example Artist • Example Song</span></a><span dir="auto">Original audio</span><video poster="https://scontent.cdninstagram.com/example-poster.jpg"></video><span dir="auto">A sample video caption.</span></article>');
assert.equal(value.posts[0].text, 'A sample video caption.', 'Music labels are not the authored caption');
value = extract('ig', '<article><a href="/p/ShortCaption/"><time></time></a><div dir="auto">Original audio</div><span dir="auto">Mix: A very long music label</span><img src="https://scontent.cdninstagram.com/photo.jpg"><span dir="auto">Checking in</span></article>');
assert.equal(value.posts[0].text, 'Checking in');

value = extract('ig', '<article><a href="/reel/NestedPoster/"><time></time></a><header><img src="https://scontent.cdninstagram.com/avatar.jpg" alt="Profile picture"></header><div class="player"><div><div><video src="blob:https://www.instagram.com/session-video"></video></div></div><div class="poster"><img src="https://scontent.cdninstagram.com/nested-poster.jpg" alt="Video poster" width="1080" height="1920"></div></div></article>');
assert.equal(value.posts[0].media.length, 1, 'A nested sibling poster belongs to its video');
assert.equal(value.posts[0].media[0].kind, 'video'); assert.equal(value.posts[0].media[0].url, null);
assert.match(value.posts[0].media[0].previewURL, /nested-poster.jpg$/);
value = extract('ig', '<article><a href="/p/SeparateSlides/"><time></time></a><ul><li><div><video src="blob:https://www.instagram.com/without-poster"></video></div></li><li><img src="https://scontent.cdninstagram.com/separate-photo.jpg" alt="Separate photo"></li></ul></article>');
assert.deepEqual(value.posts[0].media.map(item => item.kind), ['video', 'image']);
assert.equal(value.posts[0].media[0].previewURL, null, 'A neighboring carousel slide is not a video poster');
assert.match(value.posts[0].media[1].url, /separate-photo.jpg$/);

value = extract('x', '<main>Something went wrong. Try reloading.</main>', '/home');
assert.equal(value.status, 'error'); assert.equal(value.errorKind, 'transient');
value = extract('x', '<main>Please wait a few minutes before you try again</main>', '/home');
assert.equal(value.status, 'error'); assert.equal(value.errorKind, 'rateLimited');
value = extract('x', '<main>Rate limit exceeded</main>', '/home');
assert.equal(value.errorKind, 'rateLimited');
value = extract('x', '<main>Something went wrong</main><input name="password">', '/i/jf/onboarding/web?mode=login');
assert.equal(value.status, 'loginRequired'); assert.equal(value.errorKind, 'authentication');
value = extract('ig', '<main>Something went wrong</main><input name="username">', '/accounts/login/');
assert.equal(value.status, 'loginRequired'); assert.equal(value.errorKind, 'authentication');
value = extract('x', '<main>Something went wrong</main>', '/account/access');
assert.equal(value.status, 'loginRequired'); assert.equal(value.errorKind, 'authentication');
// Quote cards have their own identity, caption and attachments. Everything below is
// synthetic; the extractor must never flatten a quote into its parent tweet.
const quote = (id, content, options = {}) => {
  const handle = options.handle || 'quoted_author';
  const name = options.name || 'Quoted Author';
  const element = options.element || 'div';
  const attributes = options.attributes === undefined ? 'role="link"' : options.attributes;
  return `<${element} ${attributes}><div data-testid="User-Name"><a href="/${handle}">${name}</a></div><a href="/${handle}/status/${id}"><time datetime="2026-03-04T09:00:00Z"></time></a>${content}</${element}>`;
};
const quotedPhoto = '<div data-testid="tweetPhoto"><img src="https://pbs.twimg.com/media/quoted-photo.jpg" alt="A synthetic quoted landscape" width="1200" height="800"></div>';
const parentPhoto = '<div data-testid="tweetPhoto"><img src="https://pbs.twimg.com/media/parent-photo.jpg" alt="A synthetic parent landscape" width="800" height="600"></div>';
value = extract('x', following + tweet('200', '<div data-testid="tweetText">Parent commentary</div>' + parentPhoto + quote('900', '<div data-testid="tweetText">Quoted caption</div>' + quotedPhoto)));
assert.equal(value.posts.length, 1);
assert.equal(value.posts[0].id, '200'); assert.equal(value.posts[0].author, 'Test Author');
assert.equal(value.posts[0].handle, 'tester'); assert.equal(value.posts[0].timestamp, '2026-03-05T10:00:00Z');
assert.equal(value.posts[0].text, 'Parent commentary');
assert.equal(value.posts[0].media.length, 1, 'Quoted media must not be flattened into the parent');
assert.match(value.posts[0].media[0].url, /parent-photo/);
assert.deepEqual(value.posts[0].quotedPost, {id: '900', author: 'Quoted Author', handle: 'quoted_author', text: 'Quoted caption', timestamp: '2026-03-04T09:00:00Z', media: [{kind: 'image', url: 'https://pbs.twimg.com/media/quoted-photo.jpg', previewURL: 'https://pbs.twimg.com/media/quoted-photo.jpg', altText: 'A synthetic quoted landscape', width: 1200, height: 800}], isUnavailable: false});
assert.equal(value.diagnostics.quotes, 1); assert.equal(value.diagnostics.quoteAttachments, 1);

for (const options of [{}, {attributes: 'data-testid="quoteTweet"'}, {element: 'article', attributes: 'data-testid="tweet"'}]) {
  value = extract('x', following + tweet('201', quote('901', '<div data-testid="tweetText">A quote-only post</div>', options)));
  assert.equal(value.posts.length, 1, 'A nested article is not an additional top-level post');
  assert.equal(value.posts[0].id, '201'); assert.equal(value.posts[0].text, '');
  assert.deepEqual(value.posts[0].media, []);
  assert.equal(value.posts[0].quotedPost.text, 'A quote-only post');
  assert.equal(value.posts[0].quotedPost.id, '901');
}
value = extract('x', following + tweet('202', quote('902', quotedPhoto)));
assert.equal(value.posts[0].text, ''); assert.deepEqual(value.posts[0].media, []);
assert.equal(value.posts[0].quotedPost.text, ''); assert.equal(value.posts[0].quotedPost.media.length, 1);
value = extract('x', following + tweet('203', quote('903', '<div data-testid="videoPlayer"><video src="blob:https://x.com/synthetic-quote-video" poster="https://pbs.twimg.com/media/quoted-poster.jpg"></video><img src="https://pbs.twimg.com/media/quoted-poster.jpg"></div>')));
assert.equal(value.posts[0].text, ''); assert.deepEqual(value.posts[0].media, []);
assert.equal(value.posts[0].quotedPost.media.length, 1); assert.equal(value.posts[0].quotedPost.media[0].kind, 'video');
assert.equal(value.posts[0].quotedPost.media[0].url, null); assert.match(value.posts[0].quotedPost.media[0].previewURL, /quoted-poster/);

// Quote metadata can precede the parent's metadata in DOM order.
value = extract('x', following + `<article data-testid="tweet">${quote('904', '<div data-testid="tweetText">Quoted first in DOM</div>')}<div data-testid="User-Name"><a href="/outer_author">Outer Author</a></div><a href="/outer_author/status/204"><time datetime="2026-03-06T08:00:00Z"></time></a><div data-testid="tweetText">Still the outer post</div></article>`);
assert.equal(value.posts[0].id, '204'); assert.equal(value.posts[0].handle, 'outer_author');
assert.equal(value.posts[0].author, 'Outer Author'); assert.equal(value.posts[0].timestamp, '2026-03-06T08:00:00Z');
assert.equal(value.posts[0].text, 'Still the outer post'); assert.equal(value.posts[0].quotedPost.id, '904');
value = extract('x', following + '<article data-testid="tweet"><div data-testid="tweetText">Parent with no real permalink</div>' + quote('905', '<div data-testid="tweetText">Must not lend its ID</div>') + '</article>');
assert.equal(value.posts.length, 0, 'An incomplete outer post cannot borrow a quote permalink');

value = extract('x', following + tweet('205', '<div data-testid="tweetText">Outer survives</div>' + quote('906', '<div data-testid="tweetText"><span>Ad</span></div><div data-testid="placementTracking"></div><button data-testid="like" aria-label="9.9K Likes"></button><button data-testid="retweet" aria-label="8K Reposts"></button><button data-testid="reply" aria-label="7K Replies"></button>'), '<button data-testid="like" aria-label="2 Likes"></button><button data-testid="retweet" aria-label="3 Reposts"></button><button data-testid="reply" aria-label="4 Replies"></button>'));
assert.equal(value.posts.length, 1, 'A quote ad marker must not classify the parent as an ad');
assert.equal(value.posts[0].likes, 2); assert.equal(value.posts[0].reposts, 3); assert.equal(value.posts[0].comments, 4);
value = extract('x', following + tweet('206', '<div data-testid="tweetText">Parent ad</div>' + quote('907', '<div data-testid="tweetText">Quoted content</div>'), '<div data-testid="placementTracking"></div>'));
assert.equal(value.posts.length, 0, 'Real outer ad markers still exclude the parent');

value = extract('x', following + tweet('207', '<div data-testid="quoteTweet"><span>This Post is unavailable.</span></div>'));
assert.equal(value.posts[0].text, '');
assert.deepEqual(value.posts[0].quotedPost, {id: null, author: '', handle: '', text: '', timestamp: null, media: [], isUnavailable: true});
value = extract('x', following + tweet('208', '<div role="link"><a href="/deleted_author/status/908">This Tweet was deleted by the Tweet author.</a></div>'));
assert.equal(value.posts[0].quotedPost.id, '908'); assert.equal(value.posts[0].quotedPost.isUnavailable, true);
assert.equal(value.posts[0].quotedPost.text, '');
value = extract('x', following + tweet('209', quote('909', '<div data-testid="tweetText">This Post is unavailable.</div>')));
assert.equal(value.posts[0].quotedPost.isUnavailable, false, 'An authored caption is not a missing-post notice');
assert.equal(value.posts[0].quotedPost.text, 'This Post is unavailable.');

// Merely linking another status in a caption does not make an embedded quote.
value = extract('x', following + tweet('210', '<div data-testid="tweetText">Read <a role="link" href="/linked_author/status/910">this post</a> and <span role="link"><a href="/linked_author/status/911">another URL</a></span></div>'));
assert.equal(value.posts[0].id, '210'); assert.equal(value.posts[0].quotedPost, undefined);
assert.equal(value.posts[0].text, 'Read this post and another URL');
value = extract('x', following + tweet('211', '<div data-testid="tweetText">An ordinary link preview</div><div role="link"><a href="/linked_author/status/912">https://x.com/linked_author/status/912</a></div>'));
assert.equal(value.posts[0].quotedPost, undefined);

// Keep only one quote level; do not flatten a quote-of-a-quote or emit it as a post.
const innerQuote = quote('999', '<div data-testid="tweetText">Third-level content</div><div data-testid="tweetPhoto"><img src="https://pbs.twimg.com/media/deeper-photo.jpg"></div>', {element: 'article', attributes: 'data-testid="tweet"'});
value = extract('x', following + tweet('212', '<div data-testid="quoteTweet">' + quote('913', '<div data-testid="tweetText">Immediate quote</div>' + quotedPhoto + innerQuote, {element: 'article', attributes: 'data-testid="tweet"'}) + '</div>'));
assert.equal(value.posts.length, 1); assert.equal(value.posts[0].text, '');
assert.equal(value.posts[0].quotedPost.id, '913'); assert.equal(value.posts[0].quotedPost.text, 'Immediate quote');
assert.equal(value.posts[0].quotedPost.media.length, 1); assert.match(value.posts[0].quotedPost.media[0].url, /quoted-photo/);
assert.equal(value.posts[0].quotedPost.quotedPost, undefined);

// An explicit quote card may be partly hydrated: retain its known identity without
// inventing an unavailable state, or borrowing missing fields from the parent.
value = extract('x', following + tweet('213', '<div data-testid="tweetText">Parent during hydration</div><div data-testid="quoteTweet"><a href="/hydrating_author/status/914"></a></div>'));
assert.equal(value.posts[0].quotedPost.id, '914'); assert.equal(value.posts[0].quotedPost.isUnavailable, false);
assert.equal(value.posts[0].quotedPost.text, ''); assert.equal(value.posts[0].quotedPost.timestamp, null);
// Some X quote cards are JavaScript click targets with no status href at all.
// Their attributed content is still useful, but must not acquire the parent ID.
value = extract('x', following + tweet('214', '<div role="link" tabindex="0"><div data-testid="User-Name"><span dir="auto">No Link Author</span><span>@nolink_author</span></div><time datetime="2026-03-03T07:00:00Z"></time><div data-testid="tweetText">A card without an exported permalink</div>' + quotedPhoto + '</div>'));
assert.equal(value.posts[0].id, '214'); assert.equal(value.posts[0].text, '');
assert.deepEqual(value.posts[0].media, []); assert.equal(value.posts[0].quotedPost.id, null);
assert.equal(value.posts[0].quotedPost.author, 'No Link Author'); assert.equal(value.posts[0].quotedPost.handle, 'nolink_author');
assert.equal(value.posts[0].quotedPost.timestamp, '2026-03-03T07:00:00Z');
assert.equal(value.posts[0].quotedPost.text, 'A card without an exported permalink');
assert.equal(value.posts[0].quotedPost.media.length, 1);
// A role=link around a whole ordinary article's contents is not an embedded post.
value = extract('x', following + '<article data-testid="tweet">' + quote('215', '<div data-testid="tweetText">An ordinary whole-card post</div>') + '</article>');
assert.equal(value.posts[0].id, '215'); assert.equal(value.posts[0].text, 'An ordinary whole-card post');
assert.equal(value.posts[0].quotedPost, undefined);
value = extract('x', following + '<article data-testid="tweet"><div role="link"><div data-testid="User-Name"><a href="/outer_wrapper">Wrapper Author</a></div><a href="/outer_wrapper/status/216"><time datetime="2026-03-05T10:00:00Z"></time></a><div data-testid="tweetText">Parent in a full-card link</div>' + quote('916', '<div data-testid="tweetText">The embedded quote</div>') + '</div></article>');
assert.equal(value.posts[0].id, '216'); assert.equal(value.posts[0].text, 'Parent in a full-card link');
assert.equal(value.posts[0].quotedPost.id, '916'); assert.equal(value.posts[0].quotedPost.text, 'The embedded quote');
value = extract('x', following + '<article data-testid="tweet"><div data-testid="UserAvatar-tester"><a href="/tester"><img src="https://pbs.twimg.com/profile_images/synthetic-avatar.jpg"></a></div><div data-testid="User-Name"><a href="/tester">Author After Avatar</a></div><a href="/tester/status/217"><time datetime="2026-03-05T10:00:00Z"></time></a><div data-testid="tweetText">Parent with an earlier avatar</div><div data-testid="quoteTweet"><div data-testid="UserAvatar-quoted_author"><a href="/quoted_author"><img src="https://pbs.twimg.com/profile_images/synthetic-quote-avatar.jpg"></a></div>' + quote('917', '<div data-testid="tweetText">Quote after its avatar</div>', {element: 'article', attributes: 'data-testid="tweet"'}) + '</div></article>');
assert.equal(value.posts[0].author, 'Author After Avatar'); assert.equal(value.posts[0].quotedPost.author, 'Quoted Author');
assert.deepEqual(value.posts[0].media, []); assert.deepEqual(value.posts[0].quotedPost.media, []);
console.log('Extraction fixtures passed: normal X/Instagram, auth/errors, media/carousels, isolated quote identities/text/media/video, quote-only/unavailable/hydration, nested boundaries, ad/metric separation and inline-link false positives.');

// Reply context is metadata outside the authored text and quote. Parent lookup
// only uses the exact requested permalink's explicit Conversation timeline.
const replyLabel = '<div>Replying to <a href="/tester">@tester</a> and <a href="/second">@second</a></div>';
const reply = tweet('300', replyLabel + '<div data-testid="tweetText">My response</div>' + quote('950', '<div data-testid="tweetText">Separate quote</div>'));
value = extract('x', following + reply);
assert.deepEqual(value.posts[0].replyContext, {handles: ['tester', 'second']});
assert.equal(value.posts[0].text, 'My response');
assert.equal(value.posts[0].quotedPost.id, '950');
for (const content of ['<div data-testid="tweetText">Replying to @tester</div>', '<button>Replying to @tester</button><div data-testid="tweetText">Body</div>', '<div data-testid="tweetText">Hello @tester</div>', '<div data-testid="tweetText">A post</div>' + quote('951', replyLabel + '<div data-testid="tweetText">Quoted reply</div>')]) {
  assert.equal(extract('x', following + tweet('301', content)).posts[0].replyContext, undefined);
}
const cell = content => `<div data-testid="cellInnerDiv">${content}</div>`;
const conversation = content => `<main><div data-testid="primaryColumn"><section aria-label="Timeline: Conversation">${content}</section></div></main>`;
const parent = tweet('299', '<div data-testid="tweetText">Original parent</div><div data-testid="tweetPhoto"><img src="https://pbs.twimg.com/media/reply-parent.jpg" alt="Parent image"></div>' + quote('949', '<div data-testid="tweetText">Parent’s own quote</div>' + quotedPhoto));
value = extract('xReply', conversation(cell(parent) + cell(reply)), '/tester/status/300');
assert.equal(value.status, 'ready'); assert.equal(value.posts.length, 1);
assert.equal(value.posts[0].id, '300'); assert.equal(value.posts[0].text, 'My response');
assert.equal(value.posts[0].replyContext.parent.id, '299');
assert.equal(value.posts[0].replyContext.parent.text, 'Original parent');
assert.equal(value.posts[0].replyContext.parent.media.length, 1);
assert.match(value.posts[0].replyContext.parent.media[0].url, /reply-parent/);
assert.equal(value.posts[0].quotedPost.id, '950'); assert.equal(value.posts[0].media.length, 0);
assert.equal(value.diagnostics.replyAttachments, 1);
// Adjacent Following rows, unrelated timeline sections and recipients never prove a parent.
assert.equal(extract('x', following + parent + reply).posts[1].replyContext.parent, undefined);
assert.equal(extract('xReply', `<main>${parent}${reply}</main>`, '/tester/status/300').posts[0].replyContext.parent, undefined);
assert.equal(extract('xReply', conversation(cell(parent.replaceAll('/tester', '/stranger')) + cell(reply)), '/tester/status/300').posts[0].replyContext.parent, undefined);
assert.equal(extract('xReply', conversation(cell(parent) + cell('<div role="heading">Discover more</div>') + cell(reply)), '/tester/status/300').posts[0].replyContext.parent, undefined);
assert.equal(extract('xReply', conversation(cell(parent) + cell(reply)), '/tester/status/301').status, 'loading');
assert.equal(extract('xReply', conversation(cell(parent) + cell(tweet('301', '<div data-testid="tweetText">Different reply</div>'))), '/tester/status/300').status, 'loading');
value = extract('xReply', conversation(cell('<div data-testid="tweetUnavailable">This Post is unavailable.</div>') + cell(reply)), '/i/status/300');
assert.equal(value.posts[0].replyContext.parent.isUnavailable, true);
assert.equal(extract('xReply', conversation(cell('<div>Something went wrong</div>') + cell(reply)), '/tester/status/300').posts[0].replyContext.parent, undefined);
assert.equal(extract('xReply', '<input name="password">', '/i/flow/login').status, 'loginRequired');
assert.equal(extract('xReply', '<div>Rate limit exceeded</div>', '/tester/status/300').errorKind, 'rateLimited');
// A no-label focal tweet still has ancestry when X explicitly presents it in the conversation.
value = extract('xReply', conversation(cell(parent) + cell(tweet('300', '<div data-testid="tweetText">Self thread response</div>'))), '/tester/status/300');
assert.equal(value.posts[0].replyContext.parent.id, '299');
console.log('Reply extraction fixtures passed: recipient metadata, isolated parent/response/quote media, exact thread routing, guarded ancestry, unavailable parent and auth/error preservation.');

value = extract('xReply', conversation(cell('<article><div data-testid="tweetUnavailable">This Post is unavailable.</div></article>') + cell(reply)), '/tester/status/300');
assert.equal(value.posts[0].replyContext.parent.isUnavailable, true);
value = extract('xReply', conversation(cell(tweet('298', '<div data-testid="tweetText">Older ancestor</div>')) + cell(parent) + cell(reply)), '/tester/status/300');
assert.equal(value.posts[0].replyContext.parent.id, '299', 'Only the immediate parent is retained');
