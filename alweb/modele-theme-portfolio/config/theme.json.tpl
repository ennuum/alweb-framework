{
  "site": {
    "nom": {
      "type": "text",
      "default": "{{nom}}",
      "label": "Nom (personne ou studio)"
    },
    "slogan": {
      "type": "text",
      "default": "Designer graphique et directrice artistique. Identités, éditions et sites web.",
      "label": "Présentation courte"
    }
  },
  "couleurs": {
    "primaire": {
      "type": "color",
      "default": "#7c3aed",
      "label": "Couleur principale"
    },
    "secondaire": {
      "type": "color",
      "default": "#111827",
      "label": "Couleur secondaire"
    },
    "fond": {
      "type": "color",
      "default": "#fafaf9",
      "label": "Fond"
    },
    "texte": {
      "type": "color",
      "default": "#1c1917",
      "label": "Texte"
    },
    "doux": {
      "type": "color",
      "default": "#f3f0ff",
      "label": "Fond des sections"
    }
  },
  "typographie": {
    "police": {
      "type": "font",
      "default": "Inter, system-ui, -apple-system, Segoe UI, sans-serif",
      "label": "Police"
    },
    "titres": {
      "type": "font",
      "default": "Space Grotesk, Inter, system-ui, sans-serif",
      "label": "Police des titres"
    },
    "taille": {
      "type": "size",
      "default": "17px",
      "label": "Taille du texte"
    }
  },
  "mise_en_page": {
    "largeur": {
      "type": "size",
      "default": "1240px",
      "label": "Largeur du contenu"
    },
    "barre_laterale": {
      "type": "bool",
      "default": false,
      "label": "Barre latérale du blog"
    }
  },
  "portfolio": {
    "disponible": {
      "type": "bool",
      "default": true,
      "label": "Afficher « Disponible pour de nouveaux projets »"
    },
    "courriel": {
      "type": "text",
      "default": "bonjour@exemple.fr",
      "label": "Adresse e-mail affichée"
    }
  },
  "logo": {
    "type": "image",
    "default": "images/logo.svg",
    "label": "Logo"
  },
  "menu": {
    "type": "links",
    "default": [
      {
        "label": "Projets",
        "url": "/projets"
      },
      {
        "label": "À propos",
        "url": "/about"
      },
      {
        "label": "Contact",
        "url": "/contact"
      }
    ],
    "label": "Menu"
  },
  "reseaux": {
    "type": "links",
    "default": [
      {
        "label": "Behance",
        "url": "https://www.behance.net/"
      },
      {
        "label": "Dribbble",
        "url": "https://dribbble.com/"
      },
      {
        "label": "LinkedIn",
        "url": "https://www.linkedin.com/"
      }
    ],
    "label": "Réseaux sociaux"
  },
  "pied": {
    "texte": {
      "type": "text",
      "default": "Tous droits réservés.",
      "label": "Texte du pied de page"
    }
  }
}
