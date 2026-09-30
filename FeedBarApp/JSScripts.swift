import Foundation

/// JSON envelope: status, message, posts, emptyConfirmed. Only real permalink
/// IDs enter the feed. Missing selectors mean "loading", never a successful erase.
enum JSScripts {
    static let common = #"""
    const clean = value => (value || '').replace(/\s+/g, ' ').trim();
    const text = element => clean(element && (element.innerText || element.textContent));
    const visible = element => !!element && element.getClientRects().length > 0;
    const result = (status, message, posts = [], emptyConfirmed = false, errorKind = null) => {
        const images = Array.from(document.querySelectorAll('article img'));
        const diagnostics = {
            articles: document.querySelectorAll('article').length,
            images: images.length,
            loadedImages: images.filter(img => img.complete && img.naturalWidth > 0).length,
            videos: document.querySelectorAll('article video').length,
            attachments: posts.reduce((total, post) => total + (post.media || []).length, 0),
            quotes: posts.filter(post => post.quotedPost).length,
            quoteAttachments: posts.reduce((total, post) => total + (post.quotedPost?.media || []).length, 0)
        };
        return JSON.stringify({status, message, posts, emptyConfirmed, diagnostics, errorKind});
    };
    const webURL = value => {
        if (!value) return null;
        try {
            const url = new URL(value, location.href);
            return /^https?:$/.test(url.protocol) && !url.username && !url.password ? url.href : null;
        } catch (_) { return null; }
    };
    const size = element => ({
        width: Math.round(element.videoWidth || element.naturalWidth || Number(element.getAttribute('width')) || element.clientWidth) || null,
        height: Math.round(element.videoHeight || element.naturalHeight || Number(element.getAttribute('height')) || element.clientHeight) || null
    });
    const imageURL = img => webURL(img.currentSrc) || webURL(img.getAttribute('src')) ||
        (img.getAttribute('srcset') || '').split(',').map(value => value.trim().split(/\s+/))
            .sort((a, b) => parseFloat(b[1] || '0') - parseFloat(a[1] || '0'))
            .map(value => webURL(value[0])).find(Boolean) || null;
    const outside = (node, exclusions) => !!node && !exclusions.some(root => root === node || root.contains(node));
    const scopedNodes = (root, selector, exclusions = []) => Array.from(root.querySelectorAll(selector)).filter(node => outside(node, exclusions));
    const scopedText = (root, exclusions = []) => {
        if (!root) return '';
        if (!exclusions.some(node => root.contains(node))) return text(root);
        const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
        const parts = [];
        while (walker.nextNode()) if (outside(walker.currentNode, exclusions)) parts.push(walker.currentNode.nodeValue);
        return clean(parts.join(''));
    };
    const attachments = (article, platform, exclusions = []) => {
        const media = [];
        const keys = new Set();
        const videoPosterImages = new Set();
        const add = (item, node) => {
            const key = item.previewURL || item.url;
            if ((!key && item.kind !== 'video') || (key && keys.has(key))) return;
            if (key) keys.add(key);
            media.push({item, node});
        };
        const isContentImage = img => {
            const url = imageURL(img);
            const dimensions = size(img);
            const imageLink = img.closest('a[href]');
            const profileImage = platform === 'ig' && imageLink && /^\/[A-Za-z0-9_.]+\/?$/.test(imageLink.getAttribute('href') || '');
            return outside(img, exclusions) && !profileImage && !!url && !img.closest('header, [data-testid="Tweet-User-Avatar"], a[href^="/stories/"]') &&
                !/profile picture|profile photo|avatar/i.test(clean(img.alt)) && !/\/profile_images\//.test(url) &&
                !(dimensions.width && dimensions.height && Math.max(dimensions.width, dimensions.height) < 96);
        };
        const findVideoPoster = video => {
            const slideSelector = 'li, [role="listitem"], [aria-roledescription="slide"]';
            const slide = video.closest(slideSelector);
            const explicitPoster = webURL(video.getAttribute('poster'));
            // Instagram can put the poster beside a wrapper around the video,
            // several levels above its immediate parent. Never cross a slide/list.
            for (let container = video.parentElement; container && container !== article; container = container.parentElement) {
                if (container.matches('ul, ol, [role="list"]') || scopedNodes(container, 'video', exclusions).length > 1) break;
                const candidates = scopedNodes(container, 'img', exclusions).filter(img => {
                    if (!isContentImage(img) || img.closest(slideSelector) !== slide) return false;
                    if (explicitPoster) {
                        const actual = new URL(imageURL(img));
                        const expected = new URL(explicitPoster);
                        if (actual.host !== expected.host || actual.pathname !== expected.pathname) return false;
                    }
                    const imageRect = img.getBoundingClientRect();
                    const videoRect = video.getBoundingClientRect();
                    if (imageRect.width && imageRect.height && videoRect.width && videoRect.height) {
                        const overlapWidth = Math.min(imageRect.right, videoRect.right) - Math.max(imageRect.left, videoRect.left);
                        const overlapHeight = Math.min(imageRect.bottom, videoRect.bottom) - Math.max(imageRect.top, videoRect.top);
                        if (overlapWidth <= 0 || overlapHeight <= 0) return false;
                    }
                    return true;
                });
                if (candidates.length === 1) return candidates[0];
                if (candidates.length > 1 || container === slide) break;
            }
            return null;
        };
        // A blob: URL belongs to this WebView; exporting it cannot make it playable.
        for (const video of scopedNodes(article, 'video', exclusions)) {
            const posterImage = findVideoPoster(video);
            if (posterImage) videoPosterImages.add(posterImage);
            const playback = webURL(video.currentSrc) || webURL(video.getAttribute('src')) ||
                Array.from(video.querySelectorAll('source')).map(source => webURL(source.getAttribute('src'))).find(Boolean) || null;
            const preview = webURL(video.getAttribute('poster')) || (posterImage && imageURL(posterImage)) || null;
            add({kind: 'video', url: playback, previewURL: preview, altText: clean(video.getAttribute('aria-label')) || (posterImage ? clean(posterImage.alt) : ''), ...size(video)}, video);
        }
        const selector = platform === 'x' ? '[data-testid="tweetPhoto"] img, [data-testid="videoPlayer"] img' : 'img';
        for (const img of scopedNodes(article, selector, exclusions)) {
            if (videoPosterImages.has(img)) continue;
            const alt = clean(img.alt);
            const url = imageURL(img);
            const dimensions = size(img);
            if (!isContentImage(img)) continue;
            const player = img.closest('[data-testid="videoPlayer"], [data-testid="videoComponent"]');
            add({kind: player ? 'video' : 'image', url: player ? null : url, previewURL: url, altText: alt, ...dimensions}, img);
        }
        // Video candidates are collected first for poster deduplication, then put
        // back into document order so mixed carousels keep their original sequence.
        media.sort((a, b) => a.node === b.node ? 0 :
            (a.node.compareDocumentPosition(b.node) & Node.DOCUMENT_POSITION_FOLLOWING ? -1 : 1));
        return media.slice(0, 12).map(candidate => candidate.item);
    };
    const body = text(document.body);
    const path = location.pathname;
    const hasVisible = selector => Array.from(document.querySelectorAll(selector)).some(visible);
    const count = value => {
        const match = clean(value).replace(/,/g, '').match(/([0-9]+(?:\.[0-9]+)?)\s*([KMB])?/i);
        return match ? Math.round(Number(match[1]) * ({K: 1000, M: 1000000, B: 1000000000}[String(match[2]).toUpperCase()] || 1)) : 0;
    };
    const challenge = /\/(?:challenge|checkpoint|account\/access)(?:\/|$)/i.test(path) ||
        hasVisible('iframe[src*="captcha"], input[name="verificationCode"], input[name="challenge_response"]') ||
        /^(?:Confirm you.re human|Help us confirm you own this account|Suspicious login attempt)$/im.test(document.body ? document.body.innerText : '');
    if (challenge) return result('loginRequired', 'The site needs a verification step. Open login to continue.', [], false, 'authentication');
    // Authentication takes precedence even when its page also shows a generic error.
    const authenticationRoute = /\/(?:i\/flow\/login|login|accounts\/(?:login|onetap))(?:\/|$)/.test(path) ||
        (/\/i\/jf\/onboarding\/web\/?$/.test(path) && new URLSearchParams(location.search).get('mode') === 'login');
    const profileConfirmation = !document.querySelector('article') && /Use another profile|Remove profiles from this browser/i.test(body);
    if (authenticationRoute || profileConfirmation || hasVisible('input[autocomplete="username"], input[name="username"], input[name="password"]'))
        return result('loginRequired', 'Sign in or complete the account check to refresh this feed.', [], false, 'authentication');
    if (!document.querySelector('article')) {
        if (/Rate limit exceeded|Too many requests|Please wait a few minutes|Try again later|temporarily restricted|We limit how often/i.test(body))
            return result('error', 'The site asked to slow down. Wait before refreshing again.', [], false, 'rateLimited');
        if (/Something went wrong|Couldn.t refresh feed/i.test(body))
            return result('error', 'The site could not load its feed. Your saved posts are still available.', [], false, 'transient');
    }
    """#

    static let xExtraction = "(function() {\n" + common + #"""
    if (/\/(?:i\/flow\/login|login)(?:\/|$)/.test(path) ||
        (/\/i\/jf\/onboarding\/web\/?$/.test(path) && new URLSearchParams(location.search).get('mode') === 'login') ||
        hasVisible('input[autocomplete="username"], input[name="password"]'))
        return result('loginRequired', 'Sign in to X to refresh your Following feed.');
    const tabs = Array.from(document.querySelectorAll('[role="tab"]'));
    const following = tabs.find(tab => /^Following$/i.test(text(tab)));
    if (!following) return result('loading', 'The X Following tab was not found; the site layout or language may have changed.');
    if (following.getAttribute('aria-selected') !== 'true') {
        following.click();
        return result('loading', 'Switching X to Following…');
    }
    const statusMatch = link => {
        try {
            const url = new URL(link.getAttribute('href'), location.href);
            if (!/^(?:www\.|mobile\.)?(?:x|twitter)\.com$/i.test(url.hostname)) return null;
            return url.pathname.match(/^\/([A-Za-z0-9_]+)\/status\/(\d+)(?:\/|$)/);
        } catch (_) { return null; }
    };
    const identity = (root, exclusions = []) => {
        // Caption URLs are references, not the identity of the post containing them.
        const links = scopedNodes(root, 'a[href*="/status/"]', exclusions)
            .filter(link => !link.closest('[data-testid="tweetText"]') && statusMatch(link));
        const permalink = links.find(link => scopedNodes(link, 'time', exclusions).length) || links[0];
        return {match: permalink ? statusMatch(permalink) : null,
            time: permalink ? scopedNodes(permalink, 'time', exclusions)[0] : null};
    };
    const profileLinks = (root, exclusions = []) => scopedNodes(root, 'a[href]', exclusions).filter(link => {
        if (link.closest('[data-testid="tweetText"], [data-testid="Tweet-User-Avatar"]')) return false;
        try {
            const url = new URL(link.getAttribute('href'), location.href);
            return /^(?:www\.|mobile\.)?(?:x|twitter)\.com$/i.test(url.hostname) && /^\/[A-Za-z0-9_]+\/?$/.test(url.pathname);
        } catch (_) { return false; }
    });
    const nameFor = (root, handle, exclusions = []) => {
        const names = scopedNodes(root, '[data-testid="User-Name"]', exclusions)[0];
        const matches = link => new URL(link.href).pathname.replace(/\/$/, '') === '/' + handle && scopedText(link, exclusions);
        // Empty avatar links can precede the actual author, including avatars
        // with dynamic test IDs. Prefer a nonempty link in the name header.
        const link = (names && profileLinks(names, exclusions).find(matches)) || profileLinks(root, exclusions).find(matches);
        if (link) return scopedText(link, exclusions);
        const label = names && scopedNodes(names, '[dir="auto"], span', exclusions).find(node => {
            const value = scopedText(node, exclusions);
            return !node.querySelector('span') && !node.closest('time, a[href*="/status/"]') && value &&
                value !== handle && value !== '@' + handle && !/^(?:@|[·•]|\d+\s*[smhd]$)/i.test(value);
        });
        return scopedText(label, exclusions) || handle;
    };
    const unavailableText = value => /^(?:This (?:Post|Tweet) is unavailable|This (?:Post|Tweet) (?:was|has been) deleted(?: by (?:the (?:Post|Tweet) author|its author))?|This (?:Post|Tweet) is from (?:a suspended account|an account that no longer exists))[.!]?$/i.test(clean(value));
    const isUnavailable = (root, exclusions = []) => {
        if (scopedNodes(root, '[data-testid="tweetUnavailable"], [data-testid="tweetUnavailableText"]', exclusions).length) return true;
        // The same words in an authored caption are legitimate content.
        return !scopedNodes(root, '[data-testid="User-Name"], [data-testid="tweetPhoto"], video, [data-testid="videoPlayer"]', exclusions).length &&
            !profileLinks(root, exclusions).length && unavailableText(scopedText(root, exclusions));
    };
    const quoteRoots = root => {
        const candidates = scopedNodes(root, '[data-testid="quoteTweet"], article');
        // X also uses a clickable card rather than a nested article. Require a
        // post header and identity, or an explicit unavailable notice. A status
        // URL by itself (especially inside tweetText) is never a quote card.
        for (const card of scopedNodes(root, '[role="link"]').reverse()) {
            if (card.closest('[data-testid="tweetText"], [data-testid="User-Name"], [data-testid="Tweet-User-Avatar"]')) continue;
            const children = candidates.filter(node => card !== node && card.contains(node));
            const own = identity(card, children);
            const hasHeader = scopedNodes(card, '[data-testid="User-Name"]', children).length || profileLinks(card, children).length;
            const hasTime = scopedNodes(card, 'time', children).length;
            const hasContent = scopedNodes(card, '[data-testid="tweetText"], [data-testid="tweetPhoto"], video, [data-testid="videoPlayer"]', children).length;
            // A role=link can also wrap an entire ordinary tweet. A quote card
            // has some parent post structure outside it. JavaScript-only cards
            // need no href when their own author, time and content identify them.
            const outerExclusions = [...candidates, card];
            const hasOuterPost = identity(root, outerExclusions).match ||
                scopedNodes(root, '[data-testid="User-Name"], [data-testid="tweetText"]', outerExclusions).length;
            if (hasOuterPost && ((hasHeader && (own.match || (hasTime && hasContent))) || isUnavailable(card, children))) candidates.push(card);
        }
        return candidates.filter((node, index) => candidates.indexOf(node) === index &&
            !candidates.some(other => other !== node && other.contains(node)))
            .sort((a, b) => a.compareDocumentPosition(b) & Node.DOCUMENT_POSITION_FOLLOWING ? -1 : 1);
    };
    const contentFor = (root, exclusions, media, includeMediaLabel) => {
        const caption = scopedText(scopedNodes(root, '[data-testid="tweetText"]', exclusions)[0], exclusions);
        const images = scopedNodes(root, '[data-testid="tweetPhoto"] img', exclusions);
        const alts = images.map(img => clean(img.alt)).filter(alt => alt && !/^Image$/i.test(alt));
        let content = media.length ? caption : [caption, ...alts.filter(alt => !caption.includes(alt))].filter(Boolean).join('\n');
        if (!content && (!media.length || includeMediaLabel)) {
            if (images.length) content = '[Image post]';
            else if (scopedNodes(root, 'video, [data-testid="videoPlayer"]', exclusions).length) content = '[Video post]';
        }
        return content;
    };
    const quotedPostFor = card => {
        // Explicit quote wrappers sometimes contain the quoted article itself.
        // Unwrap only when the wrapper has no independent post metadata/content.
        const nestedArticles = scopedNodes(card, 'article');
        const own = identity(card, nestedArticles);
        const contentRoot = nestedArticles.length && !own.match &&
            !scopedNodes(card, '[data-testid="User-Name"], [data-testid="tweetText"], [data-testid="tweetPhoto"], video', nestedArticles).length ? nestedArticles[0] : card;
        const exclusions = quoteRoots(contentRoot);
        const {match, time: linkedTime} = identity(contentRoot, exclusions);
        const time = linkedTime || scopedNodes(contentRoot, 'time', exclusions)[0];
        const unavailable = isUnavailable(contentRoot, exclusions);
        const profile = profileLinks(contentRoot, exclusions)[0];
        const names = scopedNodes(contentRoot, '[data-testid="User-Name"]', exclusions)[0];
        const handleLabel = names && scopedNodes(names, 'span, [dir="ltr"]', exclusions).map(node => scopedText(node, exclusions)).find(value => /^@[A-Za-z0-9_]+$/.test(value));
        const visibleHandle = (handleLabel || scopedText(names, exclusions)).match(/(?:^|\s)@([A-Za-z0-9_]+)(?:\s|$)/);
        const handle = match ? match[1] : profile ? new URL(profile.href).pathname.replace(/^\/|\/$/g, '') : visibleHandle ? visibleHandle[1] : '';
        const media = unavailable ? [] : attachments(contentRoot, 'x', exclusions);
        return {id: match ? match[2] : null, author: unavailable ? '' : nameFor(contentRoot, handle, exclusions),
            handle: unavailable ? '' : handle, text: unavailable ? '' : contentFor(contentRoot, exclusions, media, false),
            timestamp: !unavailable && time ? time.getAttribute('datetime') : null, media, isUnavailable: unavailable};
    };
    const posts = [];
    const seen = new Set();
    // A quoted article belongs to its parent; it is not another timeline entry.
    const articles = Array.from(document.querySelectorAll('article[data-testid="tweet"], article'))
        .filter(article => !article.parentElement?.closest('article'));
    for (const article of articles) {
        const quotes = quoteRoots(article);
        // Use explicit outer ad markers, not words/markers inside a quote.
        if (scopedNodes(article, '[data-testid="placementTracking"]', quotes).length ||
            scopedNodes(article, 'span', quotes).some(node => /^(Promoted|Sponsored|Ad)$/.test(scopedText(node, quotes)))) continue;
        const {match, time} = identity(article, quotes);
        if (!match || seen.has(match[2])) continue;
        const handle = match[1];
        const author = nameFor(article, handle, quotes);
        const media = attachments(article, 'x', quotes);
        const content = contentFor(article, quotes, media, true);
        const quotedPost = quotes.length ? quotedPostFor(quotes[0]) : null;
        if (!content && !media.length && !(quotedPost && (quotedPost.text || quotedPost.media.length || quotedPost.isUnavailable))) continue;
        const metric = names => {
            for (const name of names) {
                const node = scopedNodes(article, '[data-testid="' + name + '"]', quotes)[0];
                if (node) return count(node.getAttribute('aria-label') || scopedText(node, quotes));
            }
            return 0;
        };
        seen.add(match[2]);
        posts.push({id: match[2], author, handle, text: content, media,
            timestamp: time ? time.getAttribute('datetime') : null,
            likes: metric(['like', 'unlike']), reposts: metric(['retweet', 'unretweet']), comments: metric(['reply']),
            ...(quotedPost ? {quotedPost} : {})});
    }
    if (posts.length) return result('ready', '', posts);
    const empty = articles.length === 0 && /You aren.t following anyone yet|You.re not following anyone yet|Your timeline is empty/i.test(body);
    return empty ? result('ready', '', [], true) : result('loading', 'X loaded but no readable Following posts appeared.');
    })()
    """#

    static let igExtraction = "(function() {\n" + common + #"""
    if (/\/accounts\/(?:login|onetap)/.test(path) || hasVisible('input[name="username"], input[name="password"]'))
        return result('loginRequired', 'Sign in to Instagram to refresh your feed.');
    if (!document.querySelector('article') && /Use another profile|Remove profiles from this browser/i.test(body))
        return result('loginRequired', 'Confirm your saved Instagram profile and sign in to refresh your feed.');
    const posts = [];
    const seen = new Set();
    for (const article of Array.from(document.querySelectorAll('article'))) {
        if (Array.from(article.querySelectorAll('span')).some(node => /^(Sponsored|Paid partnership)$/.test(text(node)))) continue;
        const time = article.querySelector('time');
        const permalink = (time && time.closest('a[href]')) || article.querySelector('a[href*="/p/"], a[href*="/reel/"]');
        const match = permalink && (permalink.getAttribute('href') || '').match(/\/(?:p|reel)\/([A-Za-z0-9_-]+)(?:[/?#]|$)/);
        if (!match || seen.has(match[1])) continue;
        const profile = Array.from(article.querySelectorAll('header a[href], h2 a[href], a[href]')).find(link => {
            const href = link.getAttribute('href') || '';
            return /^\/[A-Za-z0-9_.]+\/?$/.test(href) && !/^\/(?:explore|direct|reels|accounts|stories)\/?$/.test(href);
        });
        const handle = profile ? (profile.getAttribute('href') || '').replace(/^\/|\/$/g, '') : '';
        // h1 is commonly used for a post caption; nested spans can duplicate whole
        // cards, so only leaf-ish spans outside the header and control area qualify.
        let caption = text(article.querySelector('h1'));
        if (!caption) {
            const candidates = Array.from(article.querySelectorAll('span[dir="auto"], div[dir="auto"]'))
                .filter(node => !node.closest('header, button, [role="button"], a[href*="/reels/audio/"]') &&
                    !node.querySelector('span[dir="auto"], div[dir="auto"]'))
                .map(text).filter(value => value && value !== handle &&
                    !/^(?:Follow|Following|View all|Add a comment|Liked by|[\d,.KM]+ likes|See translation|more)(?:\b|$)/i.test(value) &&
                    !/^(?:Original audio(?:\s*[·•—-].*)?|Mix\s*:.*)$/i.test(value));
            caption = candidates.sort((a, b) => b.length - a.length)[0] || '';
        }
        const media = attachments(article, 'ig');
        const alts = Array.from(article.querySelectorAll('img[alt]'))
            .filter(img => !img.closest('header') && !/profile picture|profile photo/i.test(img.alt))
            .map(img => clean(img.alt)).filter(Boolean);
        let content = media.length ? caption : [caption, ...alts.filter(alt => !caption.includes(alt))].filter(Boolean).join('\n');
        if (!content && article.querySelector('video')) content = '[Video post]';
        if (!content && !media.length) continue;
        seen.add(match[1]);
        posts.push({id: match[1], author: handle, handle, text: content, media,
            timestamp: time ? time.getAttribute('datetime') : null, likes: 0, reposts: 0, comments: 0});
    }
    if (posts.length) return result('ready', '', posts);
    const empty = !document.querySelector('article') && /You aren.t following anyone|You.re not following anyone|No posts yet/i.test(body);
    return empty ? result('ready', '', [], true) : result('loading', 'Instagram loaded but no readable posts appeared; its layout may have changed.');
    })()
    """#
}
