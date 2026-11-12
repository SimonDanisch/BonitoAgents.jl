document.addEventListener("DOMContentLoaded", () => {
    const video = document.getElementById("workflow-demo");
    if (!video) return;
    const play = () => video.play().catch(error => console.warn("Video playback was refused:", error));
    document.querySelector('.VPHero a[href="#watch"]')?.addEventListener("click", play);
    const chapters = [...document.querySelectorAll("[data-demo-time]")];
    for (const button of chapters) {
        button.addEventListener("click", () => {
            const seek = () => {
                const time = Number(button.dataset.demoTime);
                if (Math.abs(video.currentTime - time) < 0.01) {
                    play();
                } else {
                    video.addEventListener("seeked", play, {once: true});
                    video.currentTime = time;
                }
            };
            if (video.readyState === 0) {
                video.addEventListener("loadedmetadata", seek, {once: true});
                video.load();
            } else {
                seek();
            }
        });
    }
    video.addEventListener("timeupdate", () => {
        const active = chapters.findLast(button => video.currentTime >= Number(button.dataset.demoTime));
        for (const button of chapters) {
            if (button === active) button.setAttribute("aria-current", "true");
            else button.removeAttribute("aria-current");
        }
    });
});
