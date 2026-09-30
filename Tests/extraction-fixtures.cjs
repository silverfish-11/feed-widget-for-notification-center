// Local HTML only. Pass exported {x,ig} JSScripts JSON as argv[2]. Requires jsdom.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const {JSDOM} = require('jsdom');
const scripts = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
function extract(key, html, path = '/') {
  const dom = new JSDOM(html, {url: `https://${key === 'x' ? 'x.com' : 'www.instagram.com'}${path}`, runScripts: 'outside-only'});
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
console.log('Extraction fixtures passed: following selection, text/images/video, stable IDs, ad filtering, login/challenges, explicit empty state, site error, media-only/carousels/video posters/avatar exclusion.');
