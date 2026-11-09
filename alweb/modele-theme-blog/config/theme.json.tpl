{
  "site": {
    "nom": {
      "type": "text",
      "default": "{{nom}}",
      "label": "Nom du blog"
    },
    "slogan": {
      "type": "text",
      "default": "Carnets, idées et découvertes.",
      "label": "Slogan"
    }
  },
  "couleurs": {
    "primaire": {
      "type": "color",
      "default": "#2563eb",
      "label": "Couleur principale"
    },
    "secondaire": {
      "type": "color",
      "default": "#0f172a",
      "label": "Couleur secondaire"
    },
    "fond": {
      "type": "color",
      "default": "#ffffff",
      "label": "Fond"
    },
    "texte": {
      "type": "color",
      "default": "#1e293b",
      "label": "Texte"
    },
    "doux": {
      "type": "color",
      "default": "#f1f5f9",
      "label": "Fond des sections"
    }
  },
  "typographie": {
    "police": {
      "type": "font",
      "default": "Inter, system-ui, -apple-system, Segoe UI, sans-serif",
      "label": "Police de l'interface"
    },
    "lecture": {
      "type": "font",
      "default": "Georgia, Cambria, Times New Roman, serif",
      "label": "Police des articles"
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
      "default": "1120px",
      "label": "Largeur du contenu"
    },
    "barre_laterale": {
      "type": "bool",
      "default": true,
      "label": "Barre latérale"
    }
  },
  "blog": {
    "auteur": {
      "type": "text",
      "default": "L'équipe de rédaction",
      "label": "Auteur présenté dans la barre latérale"
    },
    "presentation": {
      "type": "text",
      "default": "Nous écrivons sur ce qui nous passionne : des guides pratiques, des retours d'expérience et quelques coups de cœur.",
      "label": "Présentation (barre latérale)"
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
        "label": "Accueil",
        "url": "/"
      },
      {
        "label": "Articles",
        "url": "/blog"
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
        "label": "Mastodon",
        "url": "https://mastodon.social/"
      },
      {
        "label": "RSS",
        "url": "/blog"
      }
    ],
    "label": "Réseaux sociaux"
  },
  "pied": {
    "texte": {
      "type": "text",
      "default": "Textes sous licence CC BY 4.0.",
      "label": "Texte du pied de page"
    }
  }
}
