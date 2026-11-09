// Menu sur petit écran : ouvert et fermé par le bouton « Menu ».
document.addEventListener("DOMContentLoaded", () => {
  const bouton = document.querySelector(".menu-bouton");
  const menu = document.getElementById("menu-principal");
  if (!bouton || !menu) return;
  bouton.addEventListener("click", () => {
    const ouvert = menu.classList.toggle("ouvert");
    bouton.setAttribute("aria-expanded", ouvert ? "true" : "false");
  });
});
